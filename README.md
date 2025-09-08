**University of Pennsylvania, CIS 5650: GPU Programming and Architecture,
Project 1 - Flocking**

* Thomas Shaw
  * [LinkedIn](https://www.linkedin.com/in/thomas-shaw-54468b222), [personal website](https://tlshaw.me), [GitHub](https://github.com/printer83mph), etc.
* Tested on: Fedora 42, Ryzen 7 5700x @ 4.67GHz, 32GB, RTX 2070 8GB

# Boids!!

![](images/boids_showcase.gif)

## Performance Analysis

<!-- TODO: Add your performance analysis. Graphs to include:

Framerate change with increasing # of boids for naive, scattered uniform grid, and coherent uniform grid (with and without visualization)
Framerate change with increasing block size -->


## Extra Credit

- Grid-Looping Optimization
  - This can be found in [kernel.cu](https://github.com/printer83mph/CIS5650-Project1-CUDA-Flocking/blob/0a3297f7ecc6c78a996bea0d2d22e4d4d889d054/src/kernel.cu#L485), in which we push the search radius out from the boid's current position. These points, aligned to the grid, are used as boundaries for the three nested `for` loops.