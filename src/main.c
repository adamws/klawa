#include <SDL2/SDL.h>
#include <SDL2/SDL_pixels.h>
#include <SDL2/SDL_surface.h>

#include <SDL_keycode.h>
#include <SDL_rect.h>
#include <SDL_render.h>
#include <SDL_timer.h>

#include <math.h>
#include <stdbool.h>

bool init() {
  if (SDL_Init(SDL_INIT_VIDEO) < 0) {
    return false;
  }
  return true;
}

void update(float dT) {
}

void render(SDL_Renderer* renderer) {
}

void loop(SDL_Renderer* renderer) {
  bool running = true;
  Uint32 lastUpdate = SDL_GetTicks();

  while (running) {
    // start frame timing
    Uint64 start = SDL_GetPerformanceCounter();

    SDL_Event event;

    SDL_SetRenderDrawColor(renderer, 200, 200, 200, 255);
    SDL_RenderClear(renderer);

    // event loop
    while (SDL_PollEvent(&event)) {
      switch (event.type) {
        case SDL_QUIT:
          running = false;
          break;
        case SDL_KEYDOWN:
          switch (event.key.keysym.sym) {
              case SDLK_q:
              case SDLK_ESCAPE:
                  running = false;
                  break;
              default:
                  break;
          }
          break;
        default:
          break;
      }
    }

    Uint32 current = SDL_GetTicks();
    float dT = (current - lastUpdate) / 1000.0f;

    update(dT);

    lastUpdate = current;

    render(renderer);

    // end frame timing
    Uint64 end = SDL_GetPerformanceCounter();
    float elapsed_ms = (end - start) / (float) SDL_GetPerformanceFrequency() * 1000.0f;

    // cap to ~60 FPS
    SDL_Delay(floor(16.666f - elapsed_ms));

    SDL_RenderPresent(renderer);
  }
}

int main(int argc, char** argv) {
  init();

  SDL_Window* window = NULL;
  SDL_Renderer* renderer = NULL;

  int width = 1960;
  int height = 1280;
  SDL_CreateWindowAndRenderer(width, height, 0, &window, &renderer);

  loop(renderer);

  SDL_DestroyRenderer(renderer);
  SDL_DestroyWindow(window);
  SDL_Quit();

  return EXIT_SUCCESS;
}
