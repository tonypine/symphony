# Runs the test dev server (argv[1]) as a child that stays in this process group, writes the
# child's pid to ./pid, and leaves the group itself. Once the child is killed it stays a zombie
# for a second before this process reaps it, the way a slow reaper on a loaded CI runner leaves
# a killed server visible to `kill -0`.
import os
import signal
import sys
import time

# An ignored SIGCHLD, which this process may inherit, would reap the server at once.
signal.signal(signal.SIGCHLD, signal.SIG_DFL)
read_end, write_end = os.pipe()
server = os.fork()

if server == 0:
    os.close(read_end)
    os.set_inheritable(write_end, True)

    with open("pid", "w") as pid_file:
        pid_file.write(f"{os.getpid()}\n")

    os.execvp(sys.executable, [sys.executable, sys.argv[1]])

os.close(write_end)
os.setpgid(0, 0)
# The pipe reads end of file once the server has exited; it is a zombie until the waitpid.
os.read(read_end, 1)
time.sleep(1)
os.waitpid(server, 0)
