"""The test of noblue.

It builds noblue from noblue.asm, then runs it many times. Each time,
this test plays the parts noblue talks to, and checks what noblue does.

It plays two parts:

- X, the window system. The stand-in listens on a socket and speaks X's
  own words, as much of them as noblue uses. It can also misbehave on
  purpose: refuse, lie about lengths, answer late, or hang up.
- The graphics cards. Linux stops noblue at each of its calls (a Linux
  feature named ptrace), and this test answers the calls meant for a
  card. So a card can show blue, have no table, or break off, as the
  check needs.

The checks, by group:

- The program file: no part of it both written and run.
- The key: the right one picked from a key file of several; keys for
  other computers, other displays and the network passed by; odd names
  and long files.
- The tables: each one set with red and green as they are and blue all
  0; odd sizes; many screen drivers; several screens; "noblue off".
- What was typed: wrong words, and displays that are not plain numbers.
- X misbehaving: each way must end in answer 1, with the reason said,
  and never a crash.
- Linux's check: blue found in one entry; no table; a table unset, too
  big, cut, or swapped; a card that will not answer; a list of cards
  that breaks off. Each must answer 1. These are also the only checks
  where noblue answers 0, for cards that are truly right.
- The watch: it says each change once, keeps setting the tables after
  a failure, and ends only when X ends.

A stand-in is not a real card. Also run noblue on your own screen
(README, Tests).

Run it from noblue's own folder, with fasmg and INCLUDE set as for
building. It takes about a quarter of a minute.

    python3 -I tests/noblue.py

Copyright (C) 2026 the noblue project. GPL version 3 only (LICENSE).
No warranty."""
import ctypes, os, shutil, signal, socket, struct, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
TOP = os.path.dirname(HERE)
RANDR = 140                                     # the number the stand-in X gives RandR
RANDR_NOTICE = 89                               # and the number of RandR's first notice
ROOT = 0x123                                    # the stand-in X's first root window
COOKIE = bytes(range(16))                       # the key the stand-in X lets in

fails = checks = 0
def need(ok, why):
    """One check. ok is whether it passed; why says what was checked,
    and is printed only if it failed."""
    global fails, checks
    checks += 1
    if not ok:
        fails += 1
        print('FAIL:', why)

if not os.environ.get('INCLUDE'):
    sys.exit('Set INCLUDE to the include folder of fasmg\'s x86 package first (README, Building).')
work = tempfile.mkdtemp()                       # a folder for this test's files, removed at the end
EXE = os.path.join(work, 'noblue')              # noblue, built here
try:
    built = subprocess.run(['fasmg', os.path.join(TOP, 'noblue.asm'), EXE], capture_output=True, text=True)
except FileNotFoundError:
    sys.exit('fasmg was not found. Put it on your PATH first (README, Building).')
if built.returncode:
    sys.exit('fasmg could not build noblue.asm:\n' + built.stdout + built.stderr)
os.chmod(EXE, 0o755)

with open(EXE, 'rb') as f:                      # the program file's list of its parts: each one's kind and rights
    image = f.read()
at, size, count = struct.unpack_from('<Q', image, 32)[0], *struct.unpack_from('<HH', image, 54)
parts = [struct.unpack_from('<II', image, at + n * size) for n in range(count)]
need(all(rights & 3 != 3 for kind, rights in parts),
     'no part of the program both written and run: %r' % [(hex(k), r) for k, r in parts])
need([rights for kind, rights in parts if kind == 0x6474e551] == [6],
     'the stack marked read and written, never run: %r' % [(hex(k), r) for k, r in parts])

HOST = os.uname().nodename.encode()             # this computer's name, as noblue asks Linux

def auth_file(entries):
    """Write a key file (Xauthority), and give back its name.
    Each entry is (display number, key), for this computer by its name;
    or (display number, key, family, address), to say who it is for."""
    path = os.path.join(work, 'Xauthority')
    field = lambda b: struct.pack('>H', len(b)) + b
    with open(path, 'wb') as f:
        for number, key, *where in entries:
            family, address = where or (256, HOST)
            f.write(struct.pack('>H', family) + field(address) + field(number)
                    + field(b'MIT-MAGIC-COOKIE-1') + field(key))
    return path

class Server:
    """A stand-in for X: as much of X as noblue talks to.
    It serves one run of noblue, on its own thread. What noblue sent it
    is kept, so the checks can look: the key, the tables, the requests.
    The settings below make it misbehave in one way or another."""
    def __init__(self, cookie=COOKIE, randr=True, sizes=(256, 0), notice=False, refuse_set=False,
                 vendor_said=None, crtcs_said=None, huge=False, hang_up=False,
                 refuse_first=False, late=False, rounds=None, screens=1, depths_said=2, pictures=2,
                 cut=None):
        self.cookie = cookie                    # the key: the one it lets in
        self.randr = randr                      # RandR there or not
        self.sizes = sizes                      # the tables: each screen driver's size, 0 for none
        self.notice = notice                    # X misbehaving: a notice before an answer;
        self.refuse_set = refuse_set            # a table refused;
        self.vendor_said = vendor_said          # a welcome whose maker's name's length lies;
        self.crtcs_said = crtcs_said            # a list of screen drivers whose count lies;
        self.huge = huge                        # an answer's length that wraps round when multiplied by 4;
        self.hang_up = hang_up                  # X ending just before a table is sent
        self.refuse_first = refuse_first        # the first table refused, the later ones taken;
        self.late = late                        # the answer after that refusal 1.5 seconds late;
        self.rounds = rounds                    # X ending after so many lists of screen drivers
        self.screens = screens                  # X's screens: screen k's root window ROOT + k, its
        self.depths_said = depths_said          # screen drivers from 0x40 + 0x1000 * k; a depths' count that lies
        self.pictures = pictures                # how many kinds of picture each screen's first depth lists
        self.cut = cut                          # a welcome cut short: so many bytes after its first 8
        self.watched = []                       # the root windows whose changes noblue asked to be told
        self.key, self.set, self.asked = None, {}, []    # what noblue sent: its key, its tables, its requests
        self.sets = self.lists = 0              # how many tables, and lists of screen drivers, it asked
        self.path = os.path.join(work, 'X0')
        if os.path.exists(self.path):
            os.remove(self.path)
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.bind(self.path)
        self.sock.listen(1)
        self.sock.settimeout(10)
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def read(self, c, n):
        """Exactly n bytes from noblue; EOFError if it has gone."""
        data = b''
        while len(data) < n:
            more = c.recv(n - len(data))
            if not more:
                raise EOFError
            data += more
        return data

    def serve(self):
        """Take noblue's hello, check its key, send the welcome, then
        answer its requests one by one until it goes."""
        try:
            c, _ = self.sock.accept()
        except OSError:
            return
        try:
            head = self.read(c, 12)
            names, keys = struct.unpack('<HH', head[6:10])
            name = self.read(c, (names + 3) & ~3)[:names]
            self.key = self.read(c, (keys + 3) & ~3)[:keys]
            if name != b'MIT-MAGIC-COOKIE-1' or self.key != self.cookie:
                reason = b'No protocol specified'
                c.sendall(struct.pack('<BBHHH', 0, len(reason), 11, 0, (len(reason) + 3) // 4)
                          + reason.ljust((len(reason) + 3) & ~3, b'\0'))
                return
            vendor = b'fake'
            said = len(vendor) if self.vendor_said is None else self.vendor_said
            more = struct.pack('<IIIIHHBBBBBBBB4x', 1, 0x200000, 0x1fffff, 0, said, 65535, self.screens, 0,
                               0, 0, 32, 32, 8, 255) + vendor
            for k in range(self.screens):       # each screen, then its 2 depths: one of some kinds of picture, one of none
                more += (struct.pack('<IIIIIHHHHHHIBBBB', ROOT + k, 0x20, 0xffffff, 0, 0, 1024, 768, 270, 203,
                                     1, 1, 0x21, 0, 0, 24, self.depths_said)
                         + struct.pack('<BxH4x', 24, self.pictures) + b'\x21' * 24 * self.pictures
                         + struct.pack('<BxH4x', 1, 0))
            more = more[:self.cut]
            c.sendall(struct.pack('<BBHHH', 1, 0, 11, 0, len(more) // 4) + more)
            seq = 0
            while True:
                head = self.read(c, 4)
                op, minor, length = struct.unpack('<BBH', head)
                body = self.read(c, length * 4 - 4)
                seq += 1
                self.asked.append((op, minor))
                reply = lambda extra, data=b'': c.sendall(
                    struct.pack('<BBHI', 1, 0, seq, len(extra) // 4) + data.ljust(24, b'\0') + extra)
                if op == 98 and self.huge:      # 0x40000001 pieces: 4 bytes, once multiplied
                    c.sendall(struct.pack('<BBHI', 1, 0, seq, 0x40000001) + b'\1' + b'\0' * 23 + b'\0' * 4)
                elif op == 98:                  # QueryExtension
                    reply(b'', struct.pack('<BBBB', 1 if self.randr else 0, RANDR, RANDR_NOTICE, 147))
                elif op == 43:                  # GetInputFocus
                    reply(b'')
                elif op == RANDR and minor == 0:
                    reply(b'', struct.pack('<II', 1, 5))
                elif op == RANDR and minor == 25 and self.lists == self.rounds:
                    return
                elif op == RANDR and minor == 25:
                    self.lists += 1
                    if self.notice:             # a notice first, as X may send any time
                        c.sendall(struct.pack('<BBH', RANDR_NOTICE, 0, seq) + b'\0' * 28)
                    first = 0x40 + 0x1000 * (struct.unpack('<I', body[:4])[0] - ROOT)
                    crtcs = b''.join(struct.pack('<I', first + n) for n in range(len(self.sizes)))
                    count = len(self.sizes) if self.crtcs_said is None else self.crtcs_said
                    reply(crtcs, struct.pack('<IIHHHH', 0, 0, count, 0, 0, 0))
                elif op == RANDR and minor == 22:
                    crtc = struct.unpack('<I', body[:4])[0]
                    if self.late and self.sets == 1:
                        time.sleep(1.5)
                    reply(b'', struct.pack('<H', self.sizes[(crtc - 0x40) % 0x1000]))
                    if self.hang_up:
                        return
                elif op == RANDR and minor == 24:
                    crtc, size = struct.unpack('<IH', body[:6])
                    tables = struct.unpack('<%dH' % (3 * size), body[8:8 + 6 * size])
                    self.set[crtc] = tables[:size], tables[size:2 * size], tables[2 * size:]
                    self.sets += 1
                    if self.refuse_set or self.refuse_first and self.sets == 1:
                        c.sendall(struct.pack('<BBHIHB', 0, 2, seq, size, minor, op) + b'\0' * 21)
                elif op == RANDR and minor == 4:
                    self.watched.append(struct.unpack('<I', body[:4])[0])
                else:
                    c.sendall(struct.pack('<BBH', 0, 1, seq) + b'\0' * 28)    # BadRequest
        except (EOFError, OSError):
            pass
        finally:
            c.close()

GETRESOURCES, GETCRTC, GETGAMMA = 0xC04064A0, 0xC06864A1, 0xC02064A4     # what noblue asks of a card
GETPROPERTY, GETPROPBLOB, GETPROPERTIES = 0xC04064AA, 0xC01064AC, 0xC02064B9
SETTINGS = b'DEGAMMA_LUT', b'GAMMA_LUT_SIZE', b'CTM', b'GAMMA_LUT'      # a screen driver's, as Linux names them

def lut(size, blue=0, at=None):
    """A newer color table (GAMMA_LUT), as Linux hands it over: size
    entries, each of red, green, blue and 2 bytes not used. Red and
    green climb evenly. Blue is the given value in every entry; or, if
    at is given, in that one entry only, and 0 in the rest."""
    return b''.join(struct.pack('<4H', n * 65535 // (size - 1), n * 65535 // (size - 1),
                                blue if at in (None, n) else 0, 0) for n in range(size))

def driver(new=None, old=(), on=True):
    """One screen driver of a stand-in card.
    new: its newer tables, as a list. Each time noblue asks, it gets
         the next one, and the last one from then on. An empty list
         means none is set. None means the card has no settings at
         all, as old cards.
    old: the blue list of its older table.
    on:  whether it is showing a screen."""
    return dict(new=new, old=old, on=on)

class Card:
    """A stand-in graphics card. It gives the answers Linux would give
    to each question noblue asks a card. Its screen driver n has the
    number 50 + n, and that one's newer table the number 850 + n.
    refuse: the questions it will not answer."""
    def __init__(self, *drivers, refuse=()):
        self.drivers, self.refuse = drivers, refuse     # refuse: the requests it will not answer

    def driver(self, number):
        return self.drivers[number - 50] if 50 <= number < 50 + len(self.drivers) else None

    def answer(self, request, block, mem):
        """Answer one question. request is the question's number, block
        is where noblue's form is, and mem is noblue's memory. The form
        is filled in there, as Linux would. Gives back 0 for done, or
        minus an error's number."""
        get = lambda form, at: struct.unpack(form, mem.read(block + at, struct.calcsize(form)))
        put = lambda form, at, *values: mem.write(block + at, struct.pack(form, *values))
        if request in self.refuse:
            return -22
        if request == GETRESOURCES:
            where, room = get('<Q', 8)[0], get('<I', 36)[0]
            if room >= len(self.drivers):
                mem.write(where, struct.pack('<%dI' % len(self.drivers), *range(50, 50 + len(self.drivers))))
            put('<4I', 32, 0, len(self.drivers), 0, 0)
        elif request == GETCRTC:
            d = self.driver(get('<I', 12)[0])
            if not d:
                return -2
            put('<II', 28, len(d['old']), d['on'])
        elif request == GETGAMMA:
            number, size, red, green, blue = get('<IIQQQ', 0)
            d = self.driver(number)
            if not d or size != len(d['old']):
                return -22
            straight = struct.pack('<%dH' % size, *(n * 65535 // (size - 1) for n in range(size)))
            mem.write(red, straight)
            mem.write(green, straight)
            mem.write(blue, struct.pack('<%dH' % size, *d['old']))
        elif request == GETPROPERTIES:
            where, values, room, number = get('<QQII', 0)
            d = self.driver(number)
            if not d or d['new'] is None:
                return -22
            if room >= 4:
                mem.write(where, struct.pack('<4I', 1, 2, 3, 4))
                mem.write(values, struct.pack('<4Q', 0, 4096, 0, number + 800 if d['new'] else 0))
            put('<I', 16, 4)
        elif request == GETPROPERTY:
            number = get('<I', 16)[0]
            if not 1 <= number <= 4:
                return -2
            put('32s', 24, SETTINGS[number - 1])
        elif request == GETPROPBLOB:
            number, length, where = get('<IIQ', 0)
            d = self.driver(number - 800)
            if not d or not d['new']:
                return -2
            table = d['new'].pop(0) if len(d['new']) > 1 else d['new'][0]
            if length == len(table):
                mem.write(where, table)
            put('<I', 4, len(table))
        else:
            return -25
        return 0

class Memory:
    """The memory of noblue while it runs. Linux offers it as a file,
    which the stand-in card reads noblue's forms from and writes its
    answers to."""
    def __init__(self, pid):
        self.fd = os.open('/proc/%d/mem' % pid, os.O_RDWR)
    def read(self, at, count):
        return os.pread(self.fd, count, at)
    def write(self, at, data):
        os.pwrite(self.fd, data, at)

LIBC = ctypes.CDLL(None, use_errno=True)
LIBC.ptrace.argtypes = ctypes.c_long, ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p
LIBC.ptrace.restype = ctypes.c_long
TRACEME, GETREGS, SETREGS, SYSCALL, SETOPTIONS = 0, 12, 13, 24, 0x4200   # ptrace's requests
class Registers(ctypes.Structure):              # Linux's user_regs_struct, x86-64
    _fields_ = [(name, ctypes.c_ulong) for name in
                ('r15 r14 r13 r12 rbp rbx r11 r10 r9 r8 rax rcx rdx rsi rdi orig_rax rip cs eflags rsp ss '
                 'fs_base gs_base ds es fs gs').split()]

def ptrace_allowed():
    """Does Linux let this test use ptrace? Some containers forbid it."""
    pid = os.fork()
    if pid == 0:
        os._exit(126 if LIBC.ptrace(TRACEME, 0, None, None) else 0)
    return os.WEXITSTATUS(os.waitpid(pid, 0)[1]) == 0

TRACING = ptrace_allowed()
OPENINGS = []                                   # how each stand-in card was opened, in every run

def traced(words, env, cards, spoil=None):
    """Run noblue with stand-in cards, and give back its answer and its
    words.
    cards holds each stand-in card by its file's name. Linux stops
    noblue at each call it makes (ptrace). A call to a card is answered
    here, and Linux's own call is skipped. Every other call goes on to
    Linux as usual.
    spoil: which reading of the folder's list of names is made to fail
    (1 for the first, 2 for the second), as if Linux could not read it.
    If Linux does not allow ptrace here, the answer is None, with words
    that say so."""
    lists = 0
    out, w = os.pipe()
    pid = os.fork()
    if pid == 0:                                # the new process: it becomes noblue
        try:
            os.dup2(w, 1)
            if LIBC.ptrace(TRACEME, 0, None, None):
                os._exit(126)                   # ptrace is not allowed here
            os.kill(os.getpid(), signal.SIGSTOP)
            os.execve(EXE, [EXE, *words], env)
        finally:
            os._exit(127)
    os.close(w)
    if not os.WIFSTOPPED(os.waitpid(pid, 0)[1]):
        os.close(out)
        return None, 'Linux does not allow ptrace here, so the stand-in cards cannot be tried'
    timer = threading.Timer(20, os.kill, (pid, signal.SIGKILL))    # no run may last over 20 seconds
    timer.start()
    LIBC.ptrace(SETOPTIONS, pid, None, 1 | 0x100000)     # its calls told from signals; ended if this test ends
    mem, opened, regs, entering, answer, sig = None, {}, Registers(), True, None, 0
    while True:
        LIBC.ptrace(SYSCALL, pid, None, sig)
        status = os.waitpid(pid, 0)[1]
        if not os.WIFSTOPPED(status):
            break
        sig = os.WSTOPSIG(status)
        if sig != signal.SIGTRAP | 0x80:        # a signal, passed on; but not the stop after it starts
            sig = 0 if sig == signal.SIGTRAP else sig
            continue
        sig = 0
        LIBC.ptrace(GETREGS, pid, None, ctypes.byref(regs))
        if entering:
            call, name_at, how = regs.orig_rax, regs.rdi, regs.rsi
            lists += call == 217
            if call == 217 and lists == spoil:          # this reading of the names: an error, not Linux's own call
                answer = -5
                regs.orig_rax = 2 ** 64 - 1
                LIBC.ptrace(SETREGS, pid, None, ctypes.byref(regs))
            if call == 16 and regs.rdi in opened:       # a request to a card: Linux's own call skipped
                answer = opened[regs.rdi].answer(regs.rsi, regs.rdx, mem)
                regs.orig_rax = 2 ** 64 - 1
                LIBC.ptrace(SETREGS, pid, None, ctypes.byref(regs))
        elif call == 2 and regs.rax < 2 ** 63:  # a file opened: a card's?
            mem = mem or Memory(pid)
            name = os.path.basename(mem.read(name_at, 250).split(b'\0')[0].decode('latin1'))
            opened[regs.rax] = cards.get(name)
            if not opened[regs.rax]:
                del opened[regs.rax]
            else:
                OPENINGS.append(how & 3)        # how the card was opened: 0 is for reading only
        elif answer is not None:
            regs.rax = answer % 2 ** 64
            LIBC.ptrace(SETREGS, pid, None, ctypes.byref(regs))
            answer = None
        entering = not entering
    timer.cancel()
    with os.fdopen(out, 'rb') as f:
        said = f.read().decode('latin1').strip()
    if mem:
        os.close(mem.fd)
    return (os.WEXITSTATUS(status) if os.WIFEXITED(status) else -os.WTERMSIG(status)), said

def run(server, entries=((b'0', COOKIE),), *words, cards='/nonexistent', home=None, stand_ins=None,
        spoil=None):
    """Run noblue against the stand-in X, and give back its answer and
    its words.
    entries:   what goes in its key file. Or, with home given, no key
               file is named, and noblue looks for home's .Xauthority.
    words:     what is typed after "noblue": nothing, watch, or off.
    cards:     the folder of cards it is pointed at.
    stand_ins: stand-in cards, each by its file's name.
    spoil:     as in traced."""
    if stand_ins:
        cards = tempfile.mkdtemp(dir=work)
        for name in stand_ins:
            open(os.path.join(cards, name), 'w').close()
    env = dict(DISPLAY=':0', NOBLUE_SOCKET=server.path, NOBLUE_DRI=cards)
    if home:
        env['HOME'] = home
    else:
        env['XAUTHORITY'] = auth_file(entries)
    try:
        if stand_ins:
            answer = traced(words, env, stand_ins, spoil)
        else:
            p = subprocess.run([EXE, *words], env=env, capture_output=True, text=True, timeout=20)
            answer = p.returncode, p.stdout.strip()
    except subprocess.TimeoutExpired:
        answer = None, 'no end within 20 seconds'
    server.thread.join(5)
    server.sock.close()
    return answer

def right(tables, size):
    """Is this a table as noblue should set it? Red and green must
    climb evenly from 0 to 65535 over its size, and blue must be 0 in
    every entry."""
    straight = [n * 65535 // (size - 1) for n in range(size)]
    red, green, blue = tables
    return len(blue) == size and list(red) == straight and list(green) == straight and set(blue) == {0}

s = Server()
code, said = run(s)
need(s.key == COOKIE, 'the key from the Xauthority file sent: %r' % s.key)
need(list(s.set) == [0x40], 'a table set for the screen driver with one, none for the one without: %r'
     % list(s.set))
if 0x40 in s.set:
    red, green, blue = s.set[0x40]
    straight = [n * 65535 // 255 for n in range(256)]
    need(list(red) == straight and list(green) == straight, 'red and green straight, 0 to 65535')
    need(set(blue) == {0}, 'blue 0 in all 256: %r' % sorted(set(blue))[:5])
need(code == 1 and said == 'noblue: 0 screens, 0 with no color table, blue at most 0',
     'X did all, but no card for Linux to check: answer 1, said so: %r' % ((code, said),))
need(s.asked[-1:] == [(43, 0)], 'an answer asked after the tables, so all was done: %r' % s.asked[-3:])

s = Server()
code, said = run(s, ((b'1', b'x' * 16), (b'0', COOKIE), (b'', b'y' * 16)))
need(s.key == COOKIE, 'several keys: the one for display 0 picked: %r' % s.key)

s = Server()
code, said = run(s, ((b'0', b'o' * 16, 256, b'othercomputer'), (b'0', COOKIE)))
need(s.key == COOKIE, 'another computer\'s key for display 0 first: passed by, this one\'s taken: %r' % s.key)

s = Server()
code, said = run(s, ((b'0', b'o' * 16, 256, HOST + b'x'), (b'0', COOKIE)))
need(s.key == COOKIE, 'a name only starting as this computer\'s: passed by: %r' % s.key)

s = Server()                                    # Linux keeps its release's name just after the computer's
code, said = run(s, ((b'0', COOKIE, 256, HOST.ljust(65, b'\0') + os.uname().release.encode()),))
need(s.key == b'' and code == 1,
     'a name longer than a computer\'s can be, made to match the memory after this one\'s: passed by, '
     'no key sent: %r' % ((s.key, code),))

for name, why in ((HOST + b'\0\0', 'with two 0 bytes after it'), (HOST[:-1], 'cut by one letter'),
                  (b'', 'with no letters at all')):
    s = Server()
    code, said = run(s, ((b'0', COOKIE, 256, name),))
    need(s.key == b'' and code == 1,
         'this computer\'s name %s: not exactly its name, passed by, no key sent: %r' % (why, (s.key, code)))

others = tuple((b'%d' % n, b'o' * 16) for n in range(1, 2001))
s = Server()
code, said = run(s, others + ((b'0', COOKIE),))
need(s.key == COOKIE and os.path.getsize(os.path.join(work, 'Xauthority')) > 100000,
     'a key file of over 100,000 bytes, this display\'s key last: found: %r' % ((s.key, code, said),))

long_key = bytes(range(256)) * 255 + b'end'
s = Server()
code, said = run(s, ((b'0', long_key),))
need(s.key == long_key and code == 1 and 'refused' in said,
     'a key of 65,283 bytes, nearly the longest a key file can hold: sent whole, X refuses it, '
     'answer 1: %r' % ((len(s.key or b''), code, said),))

s = Server()
code, said = run(s, ((b'0', COOKIE, 65535, b''),))
need(s.key == COOKIE, 'a key for any computer: taken: %r' % s.key)

s = Server()
code, said = run(s, ((b'0', COOKIE, 0, b'\x7f\0\0\1'),))
need(s.key == b'' and code == 1, 'a key for the network only: passed by, none sent: %r' % ((s.key, code),))

s = Server()
code, said = run(s, ((b'0', b'z' * 16),))
need(code == 1 and 'refused' in said, 'a wrong key: refused, answer 1: %r' % ((code, said),))

s = Server(randr=False)
code, said = run(s)
need(code == 1 and 'RandR' in said and not s.set, 'no RandR: answer 1, nothing set: %r' % ((code, said),))

s = Server(notice=True)
code, said = run(s)
need(0x40 in s.set and code == 1 and said.startswith('noblue: 0 screens'),
     'a notice before an answer: passed by, the tables still set: %r' % ((code, said),))

s = Server(refuse_set=True)
code, said = run(s)
need(code == 1 and 'refused' in said, 'a table refused by X: answer 1, said so: %r' % ((code, said),))

s = Server(sizes=(4096,))
code, said = run(s)
need(0x40 in s.set and right(s.set[0x40], 4096),
     'a table of 4096, as newer cards have: red and green straight, blue 0 in all')

s = Server(sizes=(255, 256))
code, said = run(s)
need(sorted(s.set) == [0x40, 0x41] and right(s.set[0x40], 255) and right(s.set[0x41], 256),
     'an odd size (255), padded right, and the next table: each whole and right: %r' % sorted(s.set))

s = Server()
code, said = run(s, ((b'0', COOKIE),), 'off')
straight = [n * 65535 // 255 for n in range(256)]
need(0x40 in s.set and all(list(t) == straight for t in s.set[0x40]) and code == 0
     and said == 'noblue: off: blue is back. Every color table is plain again. Not checked.',
     'noblue off: red, green and blue straight again, answer 0, said so: %r' % ((code, said),))

p = subprocess.run([EXE], env=dict(DISPLAY='otherpc:0'), capture_output=True, text=True, timeout=20)
need(p.returncode == 1 and 'no display' in p.stdout,
     'another computer\'s display: refused, answer 1: %r' % ((p.returncode, p.stdout.strip()),))

for display in (':123456789', ':0x', ':0.x', ':', ''):
    p = subprocess.run([EXE], env=dict(DISPLAY=display), capture_output=True, text=True, timeout=20)
    need(p.returncode == 1 and 'no display' in p.stdout,
         'the display %r, not a number of 8 figures at most, alone or with a screen\'s: refused, '
         'not guessed at: %r' % (display, (p.returncode, p.stdout.strip())))

for display in (':0.0', ':0.12', ':00000000'):
    s = Server()
    p = subprocess.run([EXE], env=dict(DISPLAY=display, NOBLUE_SOCKET=s.path, NOBLUE_DRI='/nonexistent',
                                       XAUTHORITY=auth_file(((display[1:].split('.')[0].encode(), COOKIE),))),
                       capture_output=True, text=True, timeout=20)
    s.thread.join(5)
    s.sock.close()
    need(s.key == COOKIE and 0x40 in s.set,
         'the display %r: taken, its key found, the tables set: %r' % (display, p.stdout.strip()))

for words in (['bogus'], ['off', 'extra'], ['watch', 'extra']):
    p = subprocess.run([EXE, *words], env=dict(DISPLAY='otherpc:0'), capture_output=True, text=True, timeout=20)
    need(p.returncode == 1 and 'use it as' in p.stdout,
         'the words %r: how to use it said, answer 1, nothing tried: %r' % (words, (p.returncode, p.stdout.strip())))

for cut in (0, 20, 28):
    s = Server(cut=cut)
    code, said = run(s)
    need(code == 1 and 'add up' in said and not s.set,
         'a welcome cut to %d bytes after its first 8, too short for its fixed facts: refused, '
         'answer 1: %r' % (cut, (code, said)))

s = Server(vendor_said=60000)
code, said = run(s)
need(code == 1 and 'add up' in said and not s.set,
     'a welcome whose counts lie (a maker\'s name past its end): refused, answer 1: %r' % ((code, said),))

s = Server(crtcs_said=9)
code, said = run(s)
need(code == 1 and 'add up' in said and not s.set,
     'a list of screen drivers claiming 9, holding 2: refused, answer 1: %r' % ((code, said),))

p = subprocess.run([EXE], env=dict(DISPLAY=':0', NOBLUE_SOCKET='/' + 'x' * 200), capture_output=True,
                   text=True, timeout=20)
need(p.returncode == 1 and 'too long' in p.stdout,
     'a socket name longer than its room: refused, answer 1: %r' % ((p.returncode, p.stdout.strip()),))

s = Server()
code, said = run(s, home='/' + 'h' * 5000)
need(code == 1 and 'refused' in said and s.key == b'',
     'a home folder name longer than its room: no key sent, X refuses, answer 1: %r' % ((code, said),))

s = Server(sizes=(256,) * 200)
code, said = run(s)
need(len(s.set) == 200 and all(right(t, 256) for t in s.set.values()),
     'a video wall: 200 screen drivers, each set right: %d set' % len(s.set))

s = Server(sizes=(256,) * 257)
code, said = run(s)
need(code == 1 and 'more screen drivers' in said and not s.set,
     'more than 256 screen drivers: refused, answer 1: %r' % ((code, said),))

s = Server(huge=True)
code, said = run(s)
need(code == 1 and 'add up' in said and not s.set,
     'an answer\'s length that would wrap round: refused, said so, answer 1: %r' % ((code, said),))

gone, w = os.pipe()                              # its reader gone before it prints
os.close(gone)
p = subprocess.run([EXE], env=dict(DISPLAY='otherpc:0'), stdout=w, stderr=subprocess.DEVNULL, timeout=20)
os.close(w)
need(p.returncode == 1, 'its words\' reader gone: still answer 1, not ended by a signal: %r' % p.returncode)

s = Server(hang_up=True)
code, said = run(s)
need(code == 1 and 'ended' in said,
     'X gone just before a table is sent: answer 1, said so, not ended by a signal: %r' % ((code, said),))

cards = os.path.join(work, 'dri')                # a stand-in for /dev/dri: folders cannot be opened as cards
for name in ('card0', 'card12', 'renderD128', 'cardx'):
    os.makedirs(os.path.join(cards, name))
s = Server()
code, said = run(s, cards=cards)
lines = said.split('\n')
named = sorted(l.split('/')[-1].split()[0] for l in lines if 'cannot be opened' in l)
need(code == 1 and named == ['card0', 'card12'] and lines[-1].startswith('noblue: 2 screens, 2 with no color table'),
     'cards past card9 looked at; one that cannot be opened named and counted, not passed by; '
     'renderD128 and cardx left out: %r' % ((code, said),))

unlisted = os.path.join(work, 'dri2')            # a card that opens but will not list its screens: a plain file
os.makedirs(unlisted)
open(os.path.join(unlisted, 'card3'), 'w').close()
s = Server()
code, said = run(s, cards=unlisted)
lines = said.split('\n')
need(code == 1 and len(lines) == 2 and 'card3 cannot be opened, or will not list' in lines[0]
     and lines[1].startswith('noblue: 1 screen, 1 with no color table'),
     'a card that will not list its screens: named and counted, not passed by: %r' % ((code, said),))

s = Server(sizes=(4097,))
code, said = run(s)
need(code == 1 and not s.set and said == 'noblue: a color table bigger than noblue has room for',
     'a table bigger than it holds: refused, said so, answer 1: %r' % ((code, said),))

WATCHED = ['noblue: X refused (its key, or a request)',
           'noblue: 0 screens, 0 with no color table, blue at most 0',
           'noblue: X cannot be reached, or has ended']
s = Server(refuse_first=True, rounds=3)
code, said = run(s, ((b'0', COOKIE),), 'watch')
need(code == 1 and said.split('\n') == WATCHED and s.sets == 3 and 0x40 in s.set and right(s.set[0x40], 256),
     'the watch, a table refused once: said once, set again each second (3 times), what it found said '
     'once, the end when X ends: %r' % ((code, said, s.sets),))

s = Server(refuse_first=True, late=True, rounds=3)
code, said = run(s, ((b'0', COOKIE),), 'watch')
need(code == 1 and said.split('\n') == WATCHED and s.sets == 3,
     'the watch, an answer come late after a refusal: not taken for the next request\'s, the tables '
     'still set each second: %r' % ((code, said, s.sets),))

s = Server(screens=3)
code, said = run(s)
need(sorted(s.set) == [0x40, 0x1040, 0x2040] and all(right(t, 256) for t in s.set.values()),
     'X with 3 screens: the tables of each set, not the first\'s alone: %r' % [hex(n) for n in sorted(s.set)])

s = Server(screens=3, pictures=1000)
code, said = run(s)
need(sorted(s.set) == [0x40, 0x1040, 0x2040],
     'a welcome of 72,212 bytes (3 screens, 1,000 kinds of picture each): read whole, the tables of '
     'each screen set: %r' % ((code, said, sorted(s.set)),))

s = Server(screens=2, rounds=2)
code, said = run(s, ((b'0', COOKIE),), 'watch')
need(s.watched == [ROOT, ROOT + 1] and code == 1,
     'the watch, X with 2 screens: the changes of each asked for: %r' % ((s.watched, code),))

s = Server(screens=2, depths_said=200)
code, said = run(s)
need(code == 1 and 'add up' in said and not s.set,
     'a screen claiming 200 depths, past the welcome\'s end: refused, answer 1: %r' % ((code, said),))

def checked(why, answer, line, *drivers, words=(), refuse=(), server=None, spoil=None, **more):
    """One check of Linux's check. noblue is run on a stand-in card0
    with these screen drivers (and more cards, given by name). It must
    give this answer, and this last line. Gives back all its words.
    Where Linux forbids ptrace, the check fails at once, and says so."""
    if not TRACING:
        need(False, why + ': not tried, because Linux does not allow ptrace here')
        return ''
    code, said = run(server or Server(), ((b'0', COOKIE),), *words, spoil=spoil,
                     stand_ins=dict(card0=Card(*drivers, refuse=refuse), **more))
    need(code == answer and said.split('\n')[-1] == 'noblue: ' + line, '%s: %r' % (why, (code, said)))
    return said

PASSED = '1 screen, 0 with no color table, blue at most 0'
NO_TABLE = '1 screen, 1 with no color table, blue at most 0'
checked('a newer table, blue 0 in all; a screen driver showing nothing beside it: answer 0', 0, PASSED,
        driver([lut(256)]), driver([lut(256, 65535)], on=False))
checked('a newer table with blue in its last entry alone: found, answer 1', 1,
        '1 screen, 0 with no color table, blue at most 5', driver([lut(4096, 5, 4095)]))
checked('a newer table there but none set, the older one blue 0: no table, the older not guessed at', 1,
        NO_TABLE, driver([], old=(0,) * 256))
checked('an old card, no settings: its older table, blue 0: answer 0', 0, PASSED, driver(old=(0,) * 256))
checked('an old card: its older table with blue in one entry: found, answer 1', 1,
        '1 screen, 0 with no color table, blue at most 9', driver(old=(0,) * 100 + (9,) + (0,) * 155))
checked('an old card with no older table either: no table, answer 1', 1, NO_TABLE, driver())
checked('a newer table of 4,097 entries, more than it holds: no table, answer 1', 1, NO_TABLE,
        driver([lut(4097)]))
checked('a newer table whose length cannot be read: no table, answer 1', 1, NO_TABLE,
        driver([lut(256)]), refuse=(GETPROPBLOB,))
checked('a setting whose name cannot be read: no table, the older not guessed at', 1, NO_TABLE,
        driver([lut(256)], old=(0,) * 256), refuse=(GETPROPERTY,))
checked('a screen driver that will not say what it shows: counted, unchecked, answer 1', 1, NO_TABLE,
        driver([lut(256)]), refuse=(GETCRTC,))
checked('a newer table swapped for one of another length between its two readings: no table, '
        'its old entries not taken for the new', 1, NO_TABLE, driver([lut(256), lut(512, 65535)]))
checked('two cards, the second\'s screen with full blue: both counted, answer 1', 1,
        '2 screens, 0 with no color table, blue at most 65535', driver([lut(256)]),
        card1=Card(driver([lut(256, 65535)])))
for size in (4, 12, 2047):
    checked('a newer table of %d bytes, not a whole number of 8-byte entries: no table, memory\'s '
            'leftovers not read for its blue' % size, 1, NO_TABLE, driver([b'\xff' * 4 + bytes(size - 4)]))
checked('the list of cards broken off after a card with blue 0: a card may be unseen, so a screen '
        'counted with no table, answer 1', 1, '2 screens, 1 with no color table, blue at most 0',
        driver([lut(256)]), spoil=2)
checked('the list of cards unreadable from its start: a screen counted with no table, answer 1', 1,
        NO_TABLE, driver([lut(256)]), spoil=1)
said = checked('a card of 257 screen drivers, more than it holds: counted, unchecked, said', 1, NO_TABLE,
               *[driver([lut(256)])] * 257)
need('card0 cannot be opened, or will not list' in said, 'that card named: %r' % said)
said = checked('the watch: blue 0, then blue 7, then blue 0 again: each change said once, '
               'the end when X ends', 1, 'X cannot be reached, or has ended',
               driver([lut(256)] * 2 + [lut(256, 7)] * 2 + [lut(256)]), words=('watch',),
               server=Server(sizes=(256,), rounds=4))
need(said.split('\n')[:-1] == ['noblue: ' + PASSED, 'noblue: 1 screen, 0 with no color table, blue at most 7',
                              'noblue: ' + PASSED], 'the watch\'s three lines: %r' % said)

need(len(OPENINGS) > 15 and set(OPENINGS) == {0},
     'every stand-in card, in every run above, opened for reading only: %d openings, kinds %r'
     % (len(OPENINGS), sorted(set(OPENINGS))))

shutil.rmtree(work, ignore_errors=True)
print('%d checks, %d failed' % (checks, fails))
sys.exit(1 if fails else 0)
