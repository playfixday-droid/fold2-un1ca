# проверка протокола f2pad без uinput: python3 test_dry.py путь/к/f2pad-host
import socket, subprocess, time, os, sys
env = dict(os.environ, F2PAD_TOKEN="tok12345678")
p = subprocess.Popen([sys.argv[1] if len(sys.argv) > 1 else "./f2pad-host", "--dry", "--port", "18095"], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
time.sleep(0.3)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(1)
def send(m): s.sendto(m.encode(), ("127.0.0.1", 18095))
send("bad k 30 1")                      # чужой токен - игнор
send("tok12345678 k 30 1;k 30 1;k 999 1;m 272 1;r 5 -3;w -1")
send("tok12345678 g 304 1;a 0 40000;a 2 300;a 16 -1;g 999 1")
send("tok12345678 p"); print("ping:", s.recvfrom(100)[0].decode())
send("tok12345678 u")
send("tok12345678 x;q")
out, err = p.communicate(timeout=5)
print(out); print(err)
exp = ["k 1 30 1", "m 1 272 1", "m 2 0 5", "m 2 1 -3", "m 2 8 -1", "g 1 304 1", "g 3 0 32767", "g 3 2 255", "g 3 16 -1",
       "k 1 30 0", "m 1 272 0", "g 1 304 0", "g 3 0 0", "destroy"]
miss = [e for e in exp if e not in out]
assert out.count("k 1 30 1") == 1 and "999" not in out, "дубли/плохие коды"
if miss: print("MISS", miss); sys.exit(1)
print("DRY_OK")
