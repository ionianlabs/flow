"""Stream a wav into a Flow ASR sidecar in real time (live decoder only), looping, for N seconds.
usage: python3 stream_load.py WAV SOCKET SECONDS   (used to measure Parakeet while a Nemotron stream runs)"""
import socket, struct, sys, time, wave

wav, path, secs = sys.argv[1], sys.argv[2], float(sys.argv[3])
w = wave.open(wav); assert w.getframerate() == 16000 and w.getnchannels() == 1
pcm = w.readframes(w.getnframes())
s = socket.socket(socket.AF_UNIX); s.connect(path)
def send(k, p=b""): s.sendall(k + struct.pack(">I", len(p)) + p)
send(b"S", b";live")
step = 3200  # 100 ms of int16
t0 = time.time(); i = 0; n = 0
while time.time() - t0 < secs:
    send(b"A", pcm[i:i + step]); n += 1
    i = (i + step) % max(step, len(pcm) - step)
    time.sleep(max(0, t0 + n * 0.1 - time.time()))
send(b"X"); s.close()
