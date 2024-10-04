#include <SDL2/SDL.h>
#include <SDL2/SDL_image.h>
#include <X11/Xlib.h>
#include <X11/extensions/XInput2.h>

#include "keyboard.h"

#define ARRAY_LENGTH(x) (sizeof(x) / sizeof((x)[0]))
#define MAX(a, b) (((a)>(b))?(a):(b))

#define KEY_1U_PX 64

Display* display = NULL;

SDL_Texture* keycap_texture = NULL;
int keycap_width = -1;
int keycap_height = -1;

int xi_opcode;

void render(SDL_Renderer* renderer) {
  struct Key* k = NULL;

  SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_BLEND);
  SDL_SetRenderDrawColor(renderer, 0, 0, 0, 128);

  for (int i = 0; i < ARRAY_LENGTH(keyboard); i++) {
    k = &keyboard[i];
    int x = KEY_1U_PX * k->x;
    int y = KEY_1U_PX * k->y;
    int keycap_width = KEY_1U_PX * MAX(k->width, k->width2);
    int keycap_height = KEY_1U_PX * MAX(k->height, k->height2);
    SDL_Rect src = { 0, KEY_1U_PX * ((int)(k->width * 4) - 4), keycap_width, keycap_height };
    SDL_Rect dst = { x, y, keycap_width, keycap_height };
    if (k->width == 1.25 && k->width2 == 1.5 && k->height == 2 && k->height2 == 1) {
      // iso enter
      src.x = 2 * KEY_1U_PX;
      src.y = 0;
      dst.x -= 0.25 * KEY_1U_PX;
    }
    SDL_RenderCopy(renderer, keycap_texture, &src, &dst);
    if (k->pressed) {
      SDL_RenderFillRect(renderer, &dst);
    }
  }
}

void loop(SDL_Renderer* renderer) {
  bool running = true;
  SDL_Event event;

  XIEventMask mask[2];
  XIEventMask *m;
  Window win;
  int rc;

  setvbuf(stdout, NULL, _IOLBF, 0);

  win = DefaultRootWindow(display);

  /* Select for motion events */
  m = &mask[0];
  m->deviceid = XIAllDevices;
  m->mask_len = XIMaskLen(XI_LASTEVENT);
  m->mask = calloc(m->mask_len, sizeof(char));

  m = &mask[1];
  m->deviceid = XIAllMasterDevices;
  m->mask_len = XIMaskLen(XI_LASTEVENT);
  m->mask = calloc(m->mask_len, sizeof(char));
  XISetMask(m->mask, XI_RawKeyPress);
  XISetMask(m->mask, XI_RawKeyRelease);

  XISelectEvents(display, win, &mask[0], 2);
  XSync(display, False);

  free(mask[0].mask);
  free(mask[1].mask);

  while (running) {
    SDL_SetRenderDrawColor(renderer, 200, 200, 200, 255);
    SDL_RenderClear(renderer);

    // event loop
    while (SDL_PollEvent(&event)) {
      switch (event.type) {
        case SDL_QUIT:
          running = false;
          break;
        default:
          break;
      }
    }

    int index = -1;

    XEvent ev;
    XGenericEventCookie *cookie = (XGenericEventCookie*)&ev.xcookie;
    // blocks when no events in queue, thats why no window shown
    // until first key press, to be fixed
    XNextEvent(display, (XEvent*)&ev);

    if (XGetEventData(display, cookie) &&
        cookie->type == GenericEvent &&
        cookie->extension == xi_opcode)
    {
      XIRawEvent* raw_event = cookie->data;
      switch (cookie->evtype)
      {
        case XI_RawKeyPress:
        case XI_RawKeyRelease:
          printf("keycode: %d\n", raw_event->detail);
          index = keycode_keyboard_lookup[raw_event->detail];
          if (index >= 0) {
            keyboard[index].pressed = cookie->evtype == XI_RawKeyPress;
          }
          break;
        default:
          break;
      }
    }

    XFreeEventData(display, cookie);

    render(renderer);
    SDL_RenderPresent(renderer);
  }

  XDestroyWindow(display, win);

  XSync(display, False);
  XCloseDisplay(display);
}

int main(int argc, char** argv) {
  int event, error;

  display = XOpenDisplay(NULL);

  if (display == NULL) {
    fprintf(stderr, "Unable to connect to X server\n");
    goto out;
  }

  if (!XQueryExtension(display, "XInputExtension", &xi_opcode, &event, &error)) {
    printf("X Input extension not available.\n");
    goto out;
  }

  if (SDL_Init(SDL_INIT_VIDEO) < 0) {
    printf("Failed to inidialize SDL\n");
    goto out;
  }

  SDL_EventState(SDL_KEYDOWN, SDL_IGNORE);
  SDL_EventState(SDL_KEYUP, SDL_IGNORE);

  SDL_Window* window = NULL;
  SDL_Renderer* renderer = NULL;

  int width = 960;
  int height = 320;
  SDL_CreateWindowAndRenderer(width, height, 0, &window, &renderer);
  SDL_SetWindowBordered(window, SDL_FALSE);

  SDL_Surface* keycap_surface = IMG_Load("assets/keycaps.png");
  keycap_width = keycap_surface->w;
  keycap_height = keycap_surface->h;
  keycap_texture = SDL_CreateTextureFromSurface(renderer, keycap_surface);

  loop(renderer);

  SDL_DestroyTexture(keycap_texture);
  SDL_FreeSurface(keycap_surface);

  SDL_DestroyRenderer(renderer);
  SDL_DestroyWindow(window);
  SDL_Quit();

  return EXIT_SUCCESS;
out:
  if (display)
      XCloseDisplay(display);
  return EXIT_FAILURE;
}
