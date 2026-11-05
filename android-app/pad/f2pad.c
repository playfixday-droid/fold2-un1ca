// f2pad: виртуальные клавиатура, мышь и геймпад Xbox 360 (uinput) для экранного джойстика Fold2 AI.
// Приложение шлёт UDP на 127.0.0.1:8095 строки "ТОКЕН команда;команда;...", токен - из F2PAD_TOKEN.
// Команды: k КОД 1|0 - клавиша, m КОД 1|0 - кнопка мыши (272..276), r DX DY - движение мыши,
//          w N / hw N - колесо, g КОД 1|0 - кнопка геймпада (304..318), a ОСЬ ЗНАЧ - ось геймпада
//          (0,1,3,4: -32767..32767; 2,5 курки: 0..255; 16,17 крестовина: -1..1), c k|m|g - создать устройство,
//          u - отпустить всё, x - отпустить и убрать устройства, h - «жив», p - ответ "ok ...", q - выход.
// Без пакетов 8 с - всё отпускается (приложение свернули/упало), 30 мин - выход. --dry: печать вместо uinput.
#include <linux/uinput.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

enum { DK, DM, DG, ND };
static const char *NAMES[ND] = {"Fold2 Pad Keyboard", "Fold2 Pad Mouse", "Microsoft X-Box 360 pad"};
static int fd[ND] = {-1, -1, -1}, dirty[ND], dry;
static unsigned char down[ND][KEY_CNT / 8 + 1];
static int axv[ABS_CNT];
static volatile sig_atomic_t quit;
static const int GPB[] = {BTN_SOUTH, BTN_EAST, BTN_NORTH, BTN_WEST, BTN_TL, BTN_TR, BTN_SELECT, BTN_START,
                          BTN_MODE, BTN_THUMBL, BTN_THUMBR};
static const int GPA[] = {ABS_X, ABS_Y, ABS_Z, ABS_RX, ABS_RY, ABS_RZ, ABS_HAT0X, ABS_HAT0Y};

static void emit(int d, int type, int code, int val) {
  if (dry) { printf("%c %d %d %d\n", "kmg"[d], type, code, val); return; }
  struct input_event ev;
  memset(&ev, 0, sizeof ev);
  ev.type = type; ev.code = code; ev.value = val;
  if (write(fd[d], &ev, sizeof ev) < 0 && errno != EAGAIN) perror("write");
}

static void range(int code, int *mn, int *mx) {
  if (code == ABS_Z || code == ABS_RZ) { *mn = 0; *mx = 255; }
  else if (code == ABS_HAT0X || code == ABS_HAT0Y) { *mn = -1; *mx = 1; }
  else { *mn = -32768; *mx = 32767; }
}

static int create(int d) {
  if (fd[d] >= 0) return 0;
  if (dry) { fd[d] = 1; printf("create %s\n", NAMES[d]); return 0; }
  int f = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
  if (f < 0) { perror("/dev/uinput"); return -1; }
  struct uinput_setup us;
  memset(&us, 0, sizeof us);
  us.id.bustype = BUS_USB;
  if (d == DK) {
    us.id.vendor = 0x1209; us.id.product = 0xF2A1; us.id.version = 1;
    ioctl(f, UI_SET_EVBIT, EV_KEY);
    for (int k = 1; k <= KEY_MICMUTE; k++) ioctl(f, UI_SET_KEYBIT, k);
  } else if (d == DM) {
    us.id.vendor = 0x1209; us.id.product = 0xF2A2; us.id.version = 1;
    ioctl(f, UI_SET_EVBIT, EV_KEY);
    for (int k = BTN_LEFT; k <= BTN_EXTRA; k++) ioctl(f, UI_SET_KEYBIT, k);
    ioctl(f, UI_SET_EVBIT, EV_REL);
    ioctl(f, UI_SET_RELBIT, REL_X); ioctl(f, UI_SET_RELBIT, REL_Y);
    ioctl(f, UI_SET_RELBIT, REL_WHEEL); ioctl(f, UI_SET_RELBIT, REL_HWHEEL);
    ioctl(f, UI_SET_PROPBIT, INPUT_PROP_POINTER);
  } else {
    us.id.vendor = 0x045e; us.id.product = 0x028e; us.id.version = 0x0110;  // как xpad: Android берёт его .kl
    ioctl(f, UI_SET_EVBIT, EV_KEY);
    for (unsigned i = 0; i < sizeof GPB / sizeof *GPB; i++) ioctl(f, UI_SET_KEYBIT, GPB[i]);
    ioctl(f, UI_SET_EVBIT, EV_ABS);
    for (unsigned i = 0; i < sizeof GPA / sizeof *GPA; i++) ioctl(f, UI_SET_ABSBIT, GPA[i]);
  }
  strncpy(us.name, NAMES[d], UINPUT_MAX_NAME_SIZE - 1);
  int ok = ioctl(f, UI_DEV_SETUP, &us) == 0;
  if (ok && d == DG) {
    for (unsigned i = 0; i < sizeof GPA / sizeof *GPA; i++) {
      struct uinput_abs_setup a;
      memset(&a, 0, sizeof a);
      a.code = GPA[i];
      range(GPA[i], &a.absinfo.minimum, &a.absinfo.maximum);
      if (a.absinfo.maximum > 255) { a.absinfo.fuzz = 16; a.absinfo.flat = 128; }
      if (ioctl(f, UI_ABS_SETUP, &a) < 0) { ok = 0; break; }
    }
  }
  if (!ok) {  // старые ядра: настройка записью uinput_user_dev
    struct uinput_user_dev u;
    memset(&u, 0, sizeof u);
    strncpy(u.name, NAMES[d], UINPUT_MAX_NAME_SIZE - 1);
    u.id = us.id;
    if (d == DG)
      for (unsigned i = 0; i < sizeof GPA / sizeof *GPA; i++) {
        range(GPA[i], &u.absmin[GPA[i]], &u.absmax[GPA[i]]);
        if (u.absmax[GPA[i]] > 255) { u.absfuzz[GPA[i]] = 16; u.absflat[GPA[i]] = 128; }
      }
    if (write(f, &u, sizeof u) != sizeof u) { perror("uinput_user_dev"); close(f); return -1; }
  }
  if (ioctl(f, UI_DEV_CREATE) < 0) { perror("UI_DEV_CREATE"); close(f); return -1; }
  fd[d] = f;
  fprintf(stderr, "создано: %s\n", NAMES[d]);
  usleep(120000);  // Android успевает подключить устройство - первое нажатие не теряется
  return 0;
}

static int isbit(int d, int c) { return down[d][c >> 3] >> (c & 7) & 1; }
static void setbit(int d, int c, int v) {
  if (v) down[d][c >> 3] |= 1 << (c & 7); else down[d][c >> 3] &= ~(1 << (c & 7));
}

static void key(int d, int c, int v) {
  int ok = 0;
  if (d == DK) ok = c >= 1 && c <= KEY_MICMUTE;
  else if (d == DM) ok = c >= BTN_LEFT && c <= BTN_EXTRA;
  else for (unsigned i = 0; i < sizeof GPB / sizeof *GPB; i++) ok |= GPB[i] == c;
  if (!ok) return;
  v = v != 0;
  if (isbit(d, c) == v || create(d) < 0) return;
  setbit(d, c, v);
  emit(d, EV_KEY, c, v);
  dirty[d] = 1;
}

static void axis(int c, int v) {
  int ok = 0, mn, mx;
  for (unsigned i = 0; i < sizeof GPA / sizeof *GPA; i++) ok |= GPA[i] == c;
  if (!ok) return;
  range(c, &mn, &mx);
  if (v < mn) v = mn;
  if (v > mx) v = mx;
  if (axv[c] == v || create(DG) < 0) return;
  axv[c] = v;
  emit(DG, EV_ABS, c, v);
  dirty[DG] = 1;
}

static void rel(int code, int v) {
  if (!v || create(DM) < 0) return;
  if (v > 4000) v = 4000;
  if (v < -4000) v = -4000;
  emit(DM, EV_REL, code, v);
  dirty[DM] = 1;
}

static void syn(void) {
  for (int d = 0; d < ND; d++)
    if (dirty[d] && fd[d] >= 0) { emit(d, EV_SYN, SYN_REPORT, 0); dirty[d] = 0; }
}

static void release(void) {
  for (int d = 0; d < ND; d++) {
    if (fd[d] < 0) continue;
    for (int c = 0; c < KEY_CNT; c++)
      if (isbit(d, c)) { setbit(d, c, 0); emit(d, EV_KEY, c, 0); dirty[d] = 1; }
  }
  if (fd[DG] >= 0)
    for (int c = 0; c < ABS_CNT; c++)
      if (axv[c]) { axv[c] = 0; emit(DG, EV_ABS, c, 0); dirty[DG] = 1; }
  syn();
}

static void destroy(void) {
  release();
  for (int d = 0; d < ND; d++) {
    if (fd[d] < 0) continue;
    if (dry) printf("destroy %s\n", NAMES[d]);
    else { ioctl(fd[d], UI_DEV_DESTROY); close(fd[d]); }
    fd[d] = -1;
  }
}

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec / 1e9;
}

static void onsig(int s) { (void)s; quit = 1; }

static void run(char *c, int s, struct sockaddr_in *from, socklen_t fl) {
  char op[4], t1[16];
  int b = 0;
  while (*c == ' ') c++;
  int n = sscanf(c, "%3s %15s %d", op, t1, &b);
  if (n < 1) return;
  int a = n >= 2 ? atoi(t1) : 0;
  if (!strcmp(op, "k") && n == 3) key(DK, a, b);
  else if (!strcmp(op, "m") && n == 3) key(DM, a, b);
  else if (!strcmp(op, "g") && n == 3) key(DG, a, b);
  else if (!strcmp(op, "a") && n == 3) axis(a, b);
  else if (!strcmp(op, "r") && n == 3) { rel(REL_X, a); rel(REL_Y, b); }
  else if (!strcmp(op, "w") && n >= 2) rel(REL_WHEEL, a);
  else if (!strcmp(op, "hw") && n >= 2) rel(REL_HWHEEL, a);
  else if (!strcmp(op, "c") && n >= 2) {
    const char *p = strchr("kmg", t1[0]);
    if (p && t1[0]) create(p - "kmg");
  } else if (!strcmp(op, "u")) release();
  else if (!strcmp(op, "x")) destroy();
  else if (!strcmp(op, "q")) quit = 1;
  else if (!strcmp(op, "p")) {
    char r[64];
    int l = snprintf(r, sizeof r, "ok k=%d m=%d g=%d", fd[DK] >= 0, fd[DM] >= 0, fd[DG] >= 0);
    sendto(s, r, l, 0, (struct sockaddr *)from, fl);
  }
}

int main(int argc, char **argv) {
  int port = 8095;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--dry")) dry = 1;
    else if (!strcmp(argv[i], "--port") && i + 1 < argc) port = atoi(argv[++i]);
  }
  setvbuf(stdout, NULL, _IOLBF, 0);
  const char *tok = getenv("F2PAD_TOKEN");
  if (!tok || strlen(tok) < 8) { fprintf(stderr, "нужен F2PAD_TOKEN (>= 8 символов)\n"); return 2; }
  size_t tl = strlen(tok);
  int s = socket(AF_INET, SOCK_DGRAM, 0);
  struct sockaddr_in sa;
  memset(&sa, 0, sizeof sa);
  sa.sin_family = AF_INET;
  sa.sin_port = htons(port);
  sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (s < 0 || bind(s, (struct sockaddr *)&sa, sizeof sa) < 0) { perror("bind 127.0.0.1"); return 1; }
  signal(SIGTERM, onsig); signal(SIGINT, onsig); signal(SIGHUP, onsig); signal(SIGPIPE, SIG_IGN);
  fprintf(stderr, "f2pad: 127.0.0.1:%d%s\n", port, dry ? " (dry)" : "");
  double last = now();
  int idle = 0;
  char buf[4096];
  while (!quit) {
    fd_set rs;
    FD_ZERO(&rs);
    FD_SET(s, &rs);
    struct timeval tv = {1, 0};
    int r = select(s + 1, &rs, NULL, NULL, &tv);
    double t = now();
    if (r > 0) {
      struct sockaddr_in from;
      socklen_t fl = sizeof from;
      ssize_t n = recvfrom(s, buf, sizeof buf - 1, 0, (struct sockaddr *)&from, &fl);
      if (n <= 0) continue;
      buf[n] = 0;
      if ((size_t)n <= tl || memcmp(buf, tok, tl) || buf[tl] != ' ') continue;  // чужой пакет
      last = t; idle = 0;
      char *save = NULL;
      for (char *c = strtok_r(buf + tl + 1, ";\n", &save); c && !quit; c = strtok_r(NULL, ";\n", &save))
        run(c, s, &from, fl);
      syn();
    } else if (r < 0 && errno != EINTR) { perror("select"); break; }
    if (!idle && t - last > 8) { release(); idle = 1; }
    if (t - last > 1800) { fprintf(stderr, "30 мин без команд - выход\n"); break; }
  }
  destroy();
  return 0;
}
