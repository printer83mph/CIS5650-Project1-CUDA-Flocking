#define GLM_FORCE_CUDA

#include "kernel.cuh"
#include <cuda.h>

#include <cstdio>
#include <iostream>

#include <thrust/device_vector.h>
#include <thrust/execution_policy.h>
#include <thrust/random.h>
#include <thrust/sort.h>

#include <glm/glm.hpp>

// LOOK-2.1 potentially useful for doing grid-based neighbor search
#ifndef imax
#define imax(a, b) (((a) > (b)) ? (a) : (b))
#endif

#ifndef imin
#define imin(a, b) (((a) < (b)) ? (a) : (b))
#endif

#define checkCUDAErrorWithLine(msg) checkCUDAError(msg, __LINE__)

/**
 * Check for CUDA errors; print and exit if there was a problem.
 */
void checkCUDAError(const char *msg, int line = -1) {
  cudaError_t err = cudaGetLastError();
  if (cudaSuccess != err) {
    if (line >= 0) {
      fprintf(stderr, "Line %d: ", line);
    }
    fprintf(stderr, "Cuda error: %s: %s.\n", msg, cudaGetErrorString(err));
    exit(EXIT_FAILURE);
  }
}

/*****************
 * Configuration *
 *****************/

/*! Block size used for CUDA kernel launch. */
#define blockSize 128

// LOOK-1.2 Parameters for the boids algorithm.
// These worked well in our reference implementation.
#define rule1Distance 5.0f
#define rule2Distance 3.0f
#define rule3Distance 5.0f

#define rule1Scale 0.01f
#define rule2Scale 0.1f
#define rule3Scale 0.1f

#define maxSpeed 1.0f

/*! Size of the starting area in simulation space. */
#define scene_scale 100.0f

/***********************************************
 * Kernel state (pointers are device pointers) *
 ***********************************************/

int numObjects;
dim3 threadsPerBlock(blockSize);

// LOOK-1.2 - These buffers are here to hold all your boid information.
// These get allocated for you in Boids::initSimulation.
// Consider why you would need two velocity buffers in a simulation where each
// boid cares about its neighbors' velocities.
// These are called ping-pong buffers.
glm::vec3 *dev_pos;
glm::vec3 *dev_vel1;
glm::vec3 *dev_vel2;

// LOOK-2.1 - these are NOT allocated for you. You'll have to set up the thrust
// pointers on your own too.

// For efficient sorting and the uniform grid. These should always be parallel.
int *dev_particleArrayIndices; // What index in dev_pos and dev_velX represents
                               // this particle?
int *dev_particleGridIndices;  // What grid cell is this particle in?

// needed for use with thrust
thrust::device_ptr<int> dev_thrust_particleArrayIndices;
thrust::device_ptr<int> dev_thrust_particleGridIndices;

int *dev_gridCellStartIndices; // What part of dev_particleArrayIndices belongs
int *dev_gridCellEndIndices;   // to this cell?

// Used for sorting array data for faster access
glm::vec3 *dev_pos_sorted;
glm::vec3 *dev_vel1_sorted;

// LOOK-2.1 - Grid parameters based on simulation parameters.
// These are automatically computed for you in Boids::initSimulation
int gridCellCount;
int gridSideCount;
float gridCellWidth;
float gridInverseCellWidth;
glm::vec3 gridMinimum;

/******************
 * initSimulation *
 ******************/

__host__ __device__ unsigned int hash(unsigned int a) {
  a = (a + 0x7ed55d16) + (a << 12);
  a = (a ^ 0xc761c23c) ^ (a >> 19);
  a = (a + 0x165667b1) + (a << 5);
  a = (a + 0xd3a2646c) ^ (a << 9);
  a = (a + 0xfd7046c5) + (a << 3);
  a = (a ^ 0xb55a4f09) ^ (a >> 16);
  return a;
}

/**
 * LOOK-1.2 - this is a typical helper function for a CUDA kernel.
 * Function for generating a random vec3.
 */
__host__ __device__ glm::vec3 generateRandomVec3(float time, int index) {
  thrust::default_random_engine rng(hash((int)(index * time)));
  thrust::uniform_real_distribution<float> unitDistrib(-1, 1);

  return glm::vec3((float)unitDistrib(rng), (float)unitDistrib(rng),
                   (float)unitDistrib(rng));
}

/**
 * LOOK-1.2 - This is a basic CUDA kernel.
 * CUDA kernel for generating boids with a specified mass randomly around the
 * star.
 */
__global__ void kernGenerateRandomPosArray(int time, int N, glm::vec3 *arr,
                                           float scale) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index < N) {
    glm::vec3 rand = generateRandomVec3(time, index);
    arr[index].x = scale * rand.x;
    arr[index].y = scale * rand.y;
    arr[index].z = scale * rand.z;
  }
}

/**
 * Initialize memory, update some globals
 */
void Boids::initSimulation(int N) {
  numObjects = N;
  dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

  // LOOK-1.2 - This is basic CUDA memory management and error checking.
  // Don't forget to cudaFree in  Boids::endSimulation.
  cudaMalloc((void **)&dev_pos, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_pos failed!");

  cudaMalloc((void **)&dev_vel1, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel1 failed!");

  cudaMalloc((void **)&dev_vel2, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel2 failed!");

  // LOOK-1.2 - This is a typical CUDA kernel invocation.
  kernGenerateRandomPosArray<<<fullBlocksPerGrid, blockSize>>>(
      1, numObjects, dev_pos, scene_scale);
  checkCUDAErrorWithLine("kernGenerateRandomPosArray failed!");

  // LOOK-2.1 computing grid params
  gridCellWidth =
      2.0f * std::max(std::max(rule1Distance, rule2Distance), rule3Distance);
  int halfSideCount = (int)(scene_scale / gridCellWidth) + 1;
  gridSideCount = 2 * halfSideCount;

  gridCellCount = gridSideCount * gridSideCount * gridSideCount;
  gridInverseCellWidth = 1.0f / gridCellWidth;
  float halfGridWidth = gridCellWidth * halfSideCount;
  gridMinimum.x -= halfGridWidth;
  gridMinimum.y -= halfGridWidth;
  gridMinimum.z -= halfGridWidth;

  cudaMalloc((void **)&dev_particleArrayIndices, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_particleArrayIndices failed!");

  cudaMalloc((void **)&dev_particleGridIndices, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_particleGridIndices failed!");

  dev_thrust_particleArrayIndices =
      thrust::device_pointer_cast(dev_particleArrayIndices);
  dev_thrust_particleGridIndices =
      thrust::device_pointer_cast(dev_particleGridIndices);

  cudaMalloc((void **)&dev_gridCellStartIndices, gridCellCount * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_gridCellStartIndices failed!");

  cudaMalloc((void **)&dev_gridCellEndIndices, gridCellCount * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_gridCellEndIndices failed!");

  cudaMalloc((void **)&dev_pos_sorted, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_pos_sorted failed!");

  cudaMalloc((void **)&dev_vel1_sorted, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel1_sorted failed!");

  cudaDeviceSynchronize();
}

/******************
 * copyBoidsToVBO *
 ******************/

/**
 * Copy the boid positions into the VBO so that they can be drawn by OpenGL.
 */
__global__ void kernCopyPositionsToVBO(int N, glm::vec3 *pos, float *vbo,
                                       float s_scale) {
  int index = threadIdx.x + (blockIdx.x * blockDim.x);

  float c_scale = -1.0f / s_scale;

  if (index < N) {
    vbo[4 * index + 0] = pos[index].x * c_scale;
    vbo[4 * index + 1] = pos[index].y * c_scale;
    vbo[4 * index + 2] = pos[index].z * c_scale;
    vbo[4 * index + 3] = 1.0f;
  }
}

__global__ void kernCopyVelocitiesToVBO(int N, glm::vec3 *vel, float *vbo,
                                        float s_scale) {
  int index = threadIdx.x + (blockIdx.x * blockDim.x);

  if (index < N) {
    vbo[4 * index + 0] = vel[index].x + 0.3f;
    vbo[4 * index + 1] = vel[index].y + 0.3f;
    vbo[4 * index + 2] = vel[index].z + 0.3f;
    vbo[4 * index + 3] = 1.0f;
  }
}

/**
 * Wrapper for call to the kernCopyboidsToVBO CUDA kernel.
 */
void Boids::copyBoidsToVBO(float *vbodptr_positions,
                           float *vbodptr_velocities) {
  dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);

  kernCopyPositionsToVBO<<<fullBlocksPerGrid, blockSize>>>(
      numObjects, dev_pos, vbodptr_positions, scene_scale);
  kernCopyVelocitiesToVBO<<<fullBlocksPerGrid, blockSize>>>(
      numObjects, dev_vel1, vbodptr_velocities, scene_scale);

  checkCUDAErrorWithLine("copyBoidsToVBO failed!");

  cudaDeviceSynchronize();
}

/******************
 * stepSimulation *
 ******************/

/**
 * Quick utility for getting the square of a number at compile time.
 * Used for magnitude calculations.
 */
__device__ constexpr float square(float n) { return n * n; }

/**
 * LOOK-1.2 You can use this as a helper for kernUpdateVelocityBruteForce.
 * __device__ code can be called from a __global__ context
 * Compute the new velocity on the body with index `iSelf` due to the `N` boids
 * in the `pos` and `vel` arrays.
 */
__device__ glm::vec3 computeVelocityChange(int N, int iSelf,
                                           const glm::vec3 *pos,
                                           const glm::vec3 *vel) {
  glm::vec3 posSelf = pos[iSelf];
  glm::vec3 totalVelocityChange = glm::vec3(0.0f, 0.0f, 0.0f);

  // Rule 1: boids fly towards their local perceived center of mass, which
  // excludes themselves
  glm::vec3 perceivedCenterOfMass = glm::vec3(0.0f, 0.0f, 0.0f);
  int massNeighbors = 0;
  for (int i = 0; i < N; ++i) {
    glm::vec3 posI = pos[i];
    glm::vec3 distance = posI - posSelf;
    if (i == iSelf || (glm::dot(distance, distance) > square(rule1Distance)))
      continue;

    massNeighbors++;
    perceivedCenterOfMass += posI;
  }
  if (massNeighbors > 0) {
    perceivedCenterOfMass /= massNeighbors;
    totalVelocityChange += (perceivedCenterOfMass - posSelf) * rule1Scale;
  }

  // Rule 2: boids try to stay a distance d away from each other
  glm::vec3 c = glm::vec3(0.0f, 0.0f, 0.0f);

  for (int i = 0; i < N; ++i) {
    glm::vec3 posI = pos[i];
    glm::vec3 distance = posI - posSelf;
    if (i == iSelf || (glm::dot(distance, distance) > square(rule2Distance)))
      continue;

    c -= distance;
  }
  totalVelocityChange += c * rule2Scale;

  // Rule 3: boids try to match the speed of surrounding boids
  glm::vec3 perceivedVelocity = glm::vec3(0.0f, 0.0f, 0.0f);
  int velocityNeighbors = 0;
  for (int i = 0; i < N; ++i) {
    glm::vec3 posI = pos[i];
    glm::vec3 distance = posI - posSelf;
    if (i == iSelf || (glm::dot(distance, distance) > square(rule3Distance)))
      continue;

    velocityNeighbors++;
    perceivedVelocity += vel[i];
  }
  if (velocityNeighbors > 0) {
    perceivedVelocity /= velocityNeighbors;
    totalVelocityChange += perceivedVelocity * rule3Scale;
  }

  // Return total velocity change
  return totalVelocityChange;
}

/**
 * TODO-1.2 implement basic flocking
 * For each of the `N` bodies, update its position based on its current
 * velocity.
 */
__global__ void kernUpdateVelocityBruteForce(int N, glm::vec3 *pos,
                                             glm::vec3 *vel1, glm::vec3 *vel2) {
  // Compute a new velocity based on pos and vel1
  int index = threadIdx.x + (blockIdx.x * blockDim.x);
  if (index >= N) {
    return;
  }
  glm::vec3 thisVel = vel1[index];
  glm::vec3 newVel = thisVel + computeVelocityChange(N, index, pos, vel1);

  // Clamp the speed
  float newSpeedSquared = glm::dot(newVel, newVel);
  if (newSpeedSquared > square(maxSpeed)) {
    newVel = newVel / sqrt(newSpeedSquared) * maxSpeed;
  }

  // Record the new velocity into vel2. Question: why NOT vel1?
  vel2[index] = newVel;
}

/**
 * LOOK-1.2 Since this is pretty trivial, we implemented it for you.
 * For each of the `N` bodies, update its position based on its current
 * velocity.
 */
__global__ void kernUpdatePos(int N, float dt, glm::vec3 *pos, glm::vec3 *vel) {
  // Update position by velocity
  int index = threadIdx.x + (blockIdx.x * blockDim.x);
  if (index >= N) {
    return;
  }
  glm::vec3 thisPos = pos[index];
  thisPos += vel[index] * dt;

  // Wrap the boids around so we don't lose them
  thisPos.x = thisPos.x < -scene_scale ? scene_scale : thisPos.x;
  thisPos.y = thisPos.y < -scene_scale ? scene_scale : thisPos.y;
  thisPos.z = thisPos.z < -scene_scale ? scene_scale : thisPos.z;

  thisPos.x = thisPos.x > scene_scale ? -scene_scale : thisPos.x;
  thisPos.y = thisPos.y > scene_scale ? -scene_scale : thisPos.y;
  thisPos.z = thisPos.z > scene_scale ? -scene_scale : thisPos.z;

  pos[index] = thisPos;
}

// LOOK-2.1 Consider this method of computing a 1D index from a 3D grid index.
// LOOK-2.3 Looking at this method, what would be the most memory efficient
//          order for iterating over neighboring grid cells?
//          for(x)
//            for(y)
//             for(z)? Or some other order?
//
// Note to self - match largest factors with outermost for loops, such that
// the iteration goes through indices contiguously
__device__ int gridIndex3Dto1D(int x, int y, int z, int gridResolution) {
  return x + y * gridResolution + z * gridResolution * gridResolution;
}

__device__ glm::ivec3 gridIndex1Dto3D(int index, int gridResolution) {
  return glm::ivec3(index % gridResolution,
                    (index / gridResolution) % gridResolution,
                    (index / (gridResolution * gridResolution)));
}

__global__ void kernComputeIndices(int N, int gridResolution, glm::vec3 gridMin,
                                   float inverseCellWidth, glm::vec3 *pos,
                                   int *indices, int *gridIndices) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index >= N)
    return;

  glm::vec3 posSelf = pos[index];

  glm::vec3 gridPos = glm::floor((posSelf - gridMin) * inverseCellWidth);

  indices[index] = index;
  gridIndices[index] =
      gridIndex3Dto1D(gridPos.x, gridPos.y, gridPos.z, gridResolution);
}

// LOOK-2.1 Consider how this could be useful for indicating that a cell
//          does not enclose any boids
__global__ void kernResetIntBuffer(int N, int *intBuffer, int value) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index < N) {
    intBuffer[index] = value;
  }
}

__global__ void kernIdentifyCellStartEnd(int N, int *particleGridIndices,
                                         int *gridCellStartIndices,
                                         int *gridCellEndIndices) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index >= N)
    return;

  // Identify the start point of each cell in the gridIndices array.
  // This is basically a parallel unrolling of a loop that goes
  // "this index doesn't match the one before it, must be a new cell!"

  int selfGridIndex = particleGridIndices[index];

  if (index == 0)
    gridCellStartIndices[selfGridIndex] = 0;

  else if (index == N - 1)
    gridCellEndIndices[selfGridIndex] = N;

  else {
    int prevGridIndex = particleGridIndices[index - 1];
    if (prevGridIndex != selfGridIndex) {
      gridCellEndIndices[prevGridIndex] = index;
      gridCellStartIndices[selfGridIndex] = index;
    }
  }
}

__device__ constexpr float cxpr_max(float a, float b) { return a > b ? a : b; }

// Update a boid's velocity using the uniform grid to reduce
// the number of boids that need to be checked.
__global__ void kernUpdateVelNeighborSearchScattered(
    int N, int gridResolution, glm::vec3 gridMin, float inverseCellWidth,
    float cellWidth, int *gridCellStartIndices, int *gridCellEndIndices,
    int *particleArrayIndices, glm::vec3 *pos, glm::vec3 *vel1,
    glm::vec3 *vel2) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index >= N) {
    return;
  }

  // This gets added to by all goobers
  glm::vec3 totalAddedVelocity = glm::vec3(0.0f, 0.0f, 0.0f);

  glm::vec3 posSelf = pos[index];
  glm::vec3 velSelf = vel1[index];

  // Identify which cells may contain neighbors. This isn't always 8. Let's set
  // the bounds based on our particle's position and the neighbor search radius.

  glm::ivec3 cellPosSelf = glm::floor((posSelf - gridMin) * inverseCellWidth);
  float neighborMaxRadius =
      cxpr_max(cxpr_max(rule1Distance, rule2Distance), rule3Distance);
  glm::vec3 searchLength = glm::vec3(neighborMaxRadius);

  glm::ivec3 gridSearchMin =
      glm::floor((posSelf - gridMin - searchLength) * inverseCellWidth);
  glm::ivec3 gridSearchMaxInclusive =
      glm::floor((posSelf - gridMin + searchLength) * inverseCellWidth);

  // Rule 1 data collection
  glm::vec3 perceivedCenterOfMass = glm::vec3(0.0f, 0.0f, 0.0f);
  int centerOfMassNeighbors = 0;
  // Rule 2 data collection
  glm::vec3 c = glm::vec3(0.0f, 0.0f, 0.0f);
  // RUle 3 data collection
  glm::vec3 perceivedVelocity = glm::vec3(0.0f, 0.0f, 0.0f);
  int velocityNeighbors = 0;

  // Iterate through all possibly influential cells
  for (int z = gridSearchMin.z; z <= gridSearchMaxInclusive.z; z++) {
    for (int y = gridSearchMin.y; y <= gridSearchMaxInclusive.y; y++) {
      for (int x = gridSearchMin.x; x <= gridSearchMaxInclusive.x; x++) {
        glm::ivec3 neighborCellPos = glm::ivec3(x, y, z);

        // Skip iteration if outside bounds
        if (neighborCellPos.x < 0 || neighborCellPos.x >= gridResolution ||
            neighborCellPos.y < 0 || neighborCellPos.y >= gridResolution ||
            neighborCellPos.z < 0 || neighborCellPos.z >= gridResolution) {
          continue;
        }

        int neighborGridCell =
            gridIndex3Dto1D(neighborCellPos.x, neighborCellPos.y,
                            neighborCellPos.z, gridResolution);

        // Get boid start/end indices for this cell
        int startIdx = gridCellStartIndices[neighborGridCell];
        int endIdx = gridCellEndIndices[neighborGridCell];

        for (int i = startIdx; i < endIdx; ++i) {
          int bufferIndex = particleArrayIndices[i];
          if (bufferIndex == index)
            continue;

          glm::vec3 posI = pos[bufferIndex];
          glm::vec3 distance = posI - posSelf;
          float distanceSq = glm::dot(distance, distance);

          // Rule 1: boids fly towards their local perceived center of mass,
          // which excludes themselves
          if (distanceSq < square(rule1Distance)) {
            centerOfMassNeighbors++;
            perceivedCenterOfMass += posI;
          }
          // Rule 2: boids try to stay a distance d away from each other
          if (distanceSq < square(rule2Distance)) {
            c -= distance;
          }
          // Rule 3: boids try to match the speed of surrounding boids
          if (distanceSq < square(rule3Distance)) {
            velocityNeighbors++;
            perceivedVelocity += vel1[bufferIndex];
          }
        }
      }
    }
  }

  // Apply rule 1 to overall velocity addition
  if (centerOfMassNeighbors > 0) {
    perceivedCenterOfMass /= centerOfMassNeighbors;
    totalAddedVelocity += (perceivedCenterOfMass - posSelf) * rule1Scale;
  }

  // Apply rule 2 to overall velocity addition
  totalAddedVelocity += c * rule2Scale;

  // Apply rule 3 to overall velocity addition
  if (velocityNeighbors > 0) {
    perceivedVelocity /= velocityNeighbors;
    totalAddedVelocity += perceivedVelocity * rule3Scale;
  }

  glm::vec3 velNew = velSelf + totalAddedVelocity;

  // Clamp the speed
  float newSpeedSquared = glm::dot(velNew, velNew);
  if (newSpeedSquared > square(maxSpeed)) {
    velNew = velNew / sqrt(newSpeedSquared) * maxSpeed;
  }

  // Record the new velocity into vel2
  vel2[index] = velNew;
}

__global__ void kernUpdateVelNeighborSearchCoherent(
    int N, int gridResolution, glm::vec3 gridMin, float inverseCellWidth,
    float cellWidth, int *gridCellStartIndices, int *gridCellEndIndices,
    glm::vec3 *pos, glm::vec3 *vel1, glm::vec3 *vel2) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index >= N) {
    return;
  }

  // This gets added to by all goobers
  glm::vec3 totalAddedVelocity = glm::vec3(0.0f, 0.0f, 0.0f);

  glm::vec3 posSelf = pos[index];
  glm::vec3 velSelf = vel1[index];

  // Identify which cells may contain neighbors. This isn't always 8. Let's set
  // the bounds based on our particle's position and the neighbor search radius.

  glm::ivec3 cellPosSelf = glm::floor((posSelf - gridMin) * inverseCellWidth);
  float neighborMaxRadius =
      cxpr_max(cxpr_max(rule1Distance, rule2Distance), rule3Distance);
  glm::vec3 searchLength = glm::vec3(neighborMaxRadius);

  glm::ivec3 gridSearchMin =
      glm::floor((posSelf - gridMin - searchLength) * inverseCellWidth);
  glm::ivec3 gridSearchMaxInclusive =
      glm::floor((posSelf - gridMin + searchLength) * inverseCellWidth);

  // Rule 1 data collection
  glm::vec3 perceivedCenterOfMass = glm::vec3(0.0f, 0.0f, 0.0f);
  int centerOfMassNeighbors = 0;
  // Rule 2 data collection
  glm::vec3 c = glm::vec3(0.0f, 0.0f, 0.0f);
  // Rule 3 data collection
  glm::vec3 perceivedVelocity = glm::vec3(0.0f, 0.0f, 0.0f);
  int velocityNeighbors = 0;

  // Iterate through all possibly influential cells
  // For memory efficiency, we go z->y->x (contiguous memory since our indexing
  // is z-major then y-major inside that)
  for (int z = gridSearchMin.z; z <= gridSearchMaxInclusive.z; z++) {
    for (int y = gridSearchMin.y; y <= gridSearchMaxInclusive.y; y++) {
      for (int x = gridSearchMin.x; x <= gridSearchMaxInclusive.x; x++) {
        glm::ivec3 neighborCellPos = glm::ivec3(x, y, z);

        // Skip iteration if outside bounds
        if (neighborCellPos.x < 0 || neighborCellPos.x >= gridResolution ||
            neighborCellPos.y < 0 || neighborCellPos.y >= gridResolution ||
            neighborCellPos.z < 0 || neighborCellPos.z >= gridResolution) {
          continue;
        }

        int neighborGridCell =
            gridIndex3Dto1D(neighborCellPos.x, neighborCellPos.y,
                            neighborCellPos.z, gridResolution);

        // Get boid start/end indices for this cell
        int startIdx = gridCellStartIndices[neighborGridCell];
        int endIdx = gridCellEndIndices[neighborGridCell];

        // Access boids directly (no stupid bufferIndex indirection)
        for (int i = startIdx; i < endIdx; ++i) {
          if (i == index)
            continue;

          glm::vec3 posI = pos[i];
          glm::vec3 distance = posI - posSelf;
          float distanceSq = glm::dot(distance, distance);

          // Rule 1: boids fly towards their local perceived center of mass,
          // which excludes themselves
          if (distanceSq < square(rule1Distance)) {
            centerOfMassNeighbors++;
            perceivedCenterOfMass += posI;
          }
          // Rule 2: boids try to stay a distance d away from each other
          if (distanceSq < square(rule2Distance)) {
            c -= distance;
          }
          // Rule 3: boids try to match the speed of surrounding boids
          if (distanceSq < square(rule3Distance)) {
            velocityNeighbors++;
            perceivedVelocity += vel1[i];
          }
        }
      }
    }
  }

  // Apply rule 1 to overall velocity addition
  if (centerOfMassNeighbors > 0) {
    perceivedCenterOfMass /= centerOfMassNeighbors;
    totalAddedVelocity += (perceivedCenterOfMass - posSelf) * rule1Scale;
  }

  // Apply rule 2 to overall velocity addition
  totalAddedVelocity += c * rule2Scale;

  // Apply rule 3 to overall velocity addition
  if (velocityNeighbors > 0) {
    perceivedVelocity /= velocityNeighbors;
    totalAddedVelocity += perceivedVelocity * rule3Scale;
  }

  glm::vec3 velNew = velSelf + totalAddedVelocity;

  // Clamp the speed
  float newSpeedSquared = glm::dot(velNew, velNew);
  if (newSpeedSquared > square(maxSpeed)) {
    velNew = velNew / sqrt(newSpeedSquared) * maxSpeed;
  }

  // Record the new velocity into vel2
  vel2[index] = velNew;
}

__global__ void kernReorderDataByIndices(int N, int *particleArrayIndices,
                                         glm::vec3 *pos, glm::vec3 *vel1,
                                         glm::vec3 *pos_sorted,
                                         glm::vec3 *vel1_sorted) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index >= N) {
    return;
  }

  int originalIndex = particleArrayIndices[index];
  pos_sorted[index] = pos[originalIndex];
  vel1_sorted[index] = vel1[originalIndex];
}

/**
 * Step the entire N-body simulation by `dt` seconds.
 */
void Boids::stepSimulationNaive(float dt) {
  dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);

  kernUpdateVelocityBruteForce<<<fullBlocksPerGrid, blockSize>>>(
      numObjects, dev_pos, dev_vel1, dev_vel2);
  checkCUDAErrorWithLine("kernUpdateVelocityBruteForce failed!");

  kernUpdatePos<<<fullBlocksPerGrid, blockSize>>>(numObjects, dt, dev_pos,
                                                  dev_vel2);

  // Ping-pong velocity arrays
  glm::vec3 *originalVel1 = dev_vel1;
  dev_vel1 = dev_vel2;
  dev_vel2 = originalVel1;
}

void Boids::stepSimulationScatteredGrid(float dt) {
  dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);

  // Label each particle with its array index and grid index
  kernComputeIndices<<<fullBlocksPerGrid, blockSize>>>(
      numObjects, gridSideCount, gridMinimum, gridInverseCellWidth, dev_pos,
      dev_particleArrayIndices, dev_particleGridIndices);
  checkCUDAErrorWithLine("kernComputeIndices failed!");

  // Arcane thrust magic to sort arrays using grid indices
  thrust::sort_by_key(dev_thrust_particleGridIndices,
                      dev_thrust_particleGridIndices + numObjects,
                      dev_thrust_particleArrayIndices);

  // Reset grid cell start/end indices
  dim3 gridBlocksPerGrid((gridCellCount + blockSize - 1) / blockSize);
  kernResetIntBuffer<<<gridBlocksPerGrid, blockSize>>>(
      gridCellCount, dev_gridCellStartIndices, 0);
  checkCUDAErrorWithLine("kernResetIntBuffer failed!");
  kernResetIntBuffer<<<gridBlocksPerGrid, blockSize>>>(
      gridCellCount, dev_gridCellEndIndices, 0);
  checkCUDAErrorWithLine("kernResetIntBuffer failed!");

  // Find start and end indices for each grid cell
  kernIdentifyCellStartEnd<<<fullBlocksPerGrid, blockSize>>>(
      numObjects, dev_particleGridIndices, dev_gridCellStartIndices,
      dev_gridCellEndIndices);
  checkCUDAErrorWithLine("kernIdentifyCellStartEnd failed!");

  // Update velocities using scattered grid neighbor search
  kernUpdateVelNeighborSearchScattered<<<fullBlocksPerGrid, blockSize>>>(
      numObjects, gridSideCount, gridMinimum, gridInverseCellWidth,
      gridCellWidth, dev_gridCellStartIndices, dev_gridCellEndIndices,
      dev_particleArrayIndices, dev_pos, dev_vel1, dev_vel2);
  checkCUDAErrorWithLine("kernUpdateVelNeighborSearchScattered failed!");

  // Update positions
  kernUpdatePos<<<fullBlocksPerGrid, blockSize>>>(numObjects, dt, dev_pos,
                                                  dev_vel2);
  checkCUDAErrorWithLine("kernUpdatePos failed!");

  // Ping-pong velocity arrays
  glm::vec3 *originalVel1 = dev_vel1;
  dev_vel1 = dev_vel2;
  dev_vel2 = originalVel1;
}

void Boids::stepSimulationCoherentGrid(float dt) {
  dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);

  // Label each particle with array index and grid index
  kernComputeIndices<<<fullBlocksPerGrid, blockSize>>>(
      numObjects, gridSideCount, gridMinimum, gridInverseCellWidth, dev_pos,
      dev_particleArrayIndices, dev_particleGridIndices);
  checkCUDAErrorWithLine("kernComputeIndices failed!");

  // Run arcane thrust magic
  thrust::sort_by_key(dev_thrust_particleGridIndices,
                      dev_thrust_particleGridIndices + numObjects,
                      dev_thrust_particleArrayIndices);

  // Reshuffle position and velocity data to match with grid cells
  cudaMalloc((void **)&dev_pos_sorted, numObjects * sizeof(glm::vec3));
  cudaMalloc((void **)&dev_vel1_sorted, numObjects * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc temp buffers failed!");

  kernReorderDataByIndices<<<fullBlocksPerGrid, blockSize>>>(
      numObjects, dev_particleArrayIndices, dev_pos, dev_vel1, dev_pos_sorted,
      dev_vel1_sorted);
  checkCUDAErrorWithLine("kernReorderDataByIndices failed!");

  // Reset grid cell start/end indices
  dim3 gridBlocksPerGrid((gridCellCount + blockSize - 1) / blockSize);
  kernResetIntBuffer<<<gridBlocksPerGrid, blockSize>>>(
      gridCellCount, dev_gridCellStartIndices, 0);
  kernResetIntBuffer<<<gridBlocksPerGrid, blockSize>>>(
      gridCellCount, dev_gridCellEndIndices, 0);
  checkCUDAErrorWithLine("kernResetIntBuffer failed!");

  // Find start and end indices for each grid cell
  kernIdentifyCellStartEnd<<<fullBlocksPerGrid, blockSize>>>(
      numObjects, dev_particleGridIndices, dev_gridCellStartIndices,
      dev_gridCellEndIndices);
  checkCUDAErrorWithLine("kernIdentifyCellStartEnd failed!");

  // Update velocities using coherent grid neighbor search
  kernUpdateVelNeighborSearchCoherent<<<fullBlocksPerGrid, blockSize>>>(
      numObjects, gridSideCount, gridMinimum, gridInverseCellWidth,
      gridCellWidth, dev_gridCellStartIndices, dev_gridCellEndIndices,
      dev_pos_sorted, dev_vel1_sorted, dev_vel2);
  checkCUDAErrorWithLine("kernUpdateVelNeighborSearchCoherent failed!");

  // Update positions using sorted position data
  kernUpdatePos<<<fullBlocksPerGrid, blockSize>>>(numObjects, dt,
                                                  dev_pos_sorted, dev_vel2);
  checkCUDAErrorWithLine("kernUpdatePos failed!");

  // Copy sorted data back to original buffers
  cudaMemcpy(dev_pos, dev_pos_sorted, numObjects * sizeof(glm::vec3),
             cudaMemcpyDeviceToDevice);
  cudaMemcpy(dev_vel1, dev_vel2, numObjects * sizeof(glm::vec3),
             cudaMemcpyDeviceToDevice);
}

void Boids::endSimulation() {
  cudaFree(dev_vel1);
  cudaFree(dev_vel2);
  cudaFree(dev_pos);

  cudaFree(dev_particleArrayIndices);
  cudaFree(dev_particleGridIndices);
  cudaFree(dev_gridCellStartIndices);
  cudaFree(dev_gridCellEndIndices);
}

void Boids::unitTest() {
  // LOOK-1.2 Feel free to write additional tests here.

  // test unstable sort
  int *dev_intKeys;
  int *dev_intValues;
  int N = 10;

  std::unique_ptr<int[]> intKeys{new int[N]};
  std::unique_ptr<int[]> intValues{new int[N]};

  intKeys[0] = 0;
  intValues[0] = 0;
  intKeys[1] = 1;
  intValues[1] = 1;
  intKeys[2] = 0;
  intValues[2] = 2;
  intKeys[3] = 3;
  intValues[3] = 3;
  intKeys[4] = 0;
  intValues[4] = 4;
  intKeys[5] = 2;
  intValues[5] = 5;
  intKeys[6] = 2;
  intValues[6] = 6;
  intKeys[7] = 0;
  intValues[7] = 7;
  intKeys[8] = 5;
  intValues[8] = 8;
  intKeys[9] = 6;
  intValues[9] = 9;

  cudaMalloc((void **)&dev_intKeys, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_intKeys failed!");

  cudaMalloc((void **)&dev_intValues, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_intValues failed!");

  dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

  std::cout << "before unstable sort: " << std::endl;
  for (int i = 0; i < N; i++) {
    std::cout << "  key: " << intKeys[i];
    std::cout << " value: " << intValues[i] << std::endl;
  }

  // How to copy data to the GPU
  cudaMemcpy(dev_intKeys, intKeys.get(), sizeof(int) * N,
             cudaMemcpyHostToDevice);
  cudaMemcpy(dev_intValues, intValues.get(), sizeof(int) * N,
             cudaMemcpyHostToDevice);

  // Wrap device vectors in thrust iterators for use with thrust.
  thrust::device_ptr<int> dev_thrust_keys(dev_intKeys);
  thrust::device_ptr<int> dev_thrust_values(dev_intValues);
  // LOOK-2.1 Example for using thrust::sort_by_key
  thrust::sort_by_key(dev_thrust_keys, dev_thrust_keys + N, dev_thrust_values);

  // How to copy data back to the CPU side from the GPU
  cudaMemcpy(intKeys.get(), dev_intKeys, sizeof(int) * N,
             cudaMemcpyDeviceToHost);
  cudaMemcpy(intValues.get(), dev_intValues, sizeof(int) * N,
             cudaMemcpyDeviceToHost);
  checkCUDAErrorWithLine("memcpy back failed!");

  std::cout << "after unstable sort: " << std::endl;
  for (int i = 0; i < N; i++) {
    std::cout << "  key: " << intKeys[i];
    std::cout << " value: " << intValues[i] << std::endl;
  }

  // cleanup
  cudaFree(dev_intKeys);
  cudaFree(dev_intValues);
  checkCUDAErrorWithLine("cudaFree failed!");
  return;
}
