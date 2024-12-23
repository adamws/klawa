import logging
import os
from os.path import isfile
import signal
import shutil
import subprocess
import sys
import threading
import time
from contextlib import contextmanager
from pathlib import Path

import pytest
from pyvirtualdisplay.smartdisplay import SmartDisplay

logger = logging.getLogger(__name__)


class LinuxVirtualScreenManager:
    def __enter__(self):
        self.display = SmartDisplay(backend="xvfb", size=(960, 320))
        self.display.start()
        return self

    def __exit__(self, *exc):
        self.display.stop()
        return False


class HostScreenManager:
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def is_xvfb_avaiable() -> bool:
    try:
        p = subprocess.Popen(
            ["Xvfb", "-help"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            shell=False,
        )
        _, _ = p.communicate()
        exit_code = p.returncode
        return exit_code == 0
    except FileNotFoundError:
        logger.warning("Xvfb was not found")
    return False


def get_screen_manager():
    if sys.platform == "linux":
        if is_xvfb_avaiable():
            return LinuxVirtualScreenManager()
        else:
            return HostScreenManager()
    else:
        pytest.skip(f"Platform '{sys.platform}' is not supported")


def set_keyboard_layout(lang):
    # Run "setxkbmap <lang> -print | xkbcomp - $DISPLAY"
    setxkbmap_process = subprocess.Popen(
        ["setxkbmap", lang, "-print"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True
    )
    xkbcomp_process = subprocess.Popen(
        ["xkbcomp", "-", os.environ["DISPLAY"]],
        stdin=setxkbmap_process.stdout,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True
    )
    # Close the stdout of the first process to allow it to receive a SIGPIPE if `xkbcomp` exits
    if setxkbmap_process.stdout:
        setxkbmap_process.stdout.close()

    output, errors = xkbcomp_process.communicate()
    if xkbcomp_process.returncode != 0:
        print(f"Error: {errors}")
    else:
        print(f"Success: {output}")


@pytest.fixture(scope="session", autouse=True)
def screen_manager():
    with get_screen_manager() as _:

        # this is a trick to keep one keyboard layout for full display lifetime,
        # otherwise server would regenerate layout on last client disconection
        # https://stackoverflow.com/questions/75919741/how-to-add-keyboard-layouts-to-xvfb
        # 1. run some app in the background for full duration on test
        # 2. configure keyboard layout
        # 3. test
        dummy = subprocess.Popen(["xlogo"])
        time.sleep(0.5)

        set_keyboard_layout("pl")

        yield

        dummy.kill()


def log_config(tmpdir) -> None:
    with open(f"{tmpdir}/config", "r") as r:
        logger.debug(r.readlines())


@pytest.fixture
def app_isolation(tmpdir, app_path, examples_dir):
    @contextmanager
    def _isolation(example):
        new_path = shutil.copy(app_path, tmpdir)
        logger.info(f"New app path: {new_path}")

        if example:
            src_dir = examples_dir / example
            for item in os.listdir(src_dir):
                src_file = src_dir / item
                if os.path.isfile(src_file):
                    shutil.copy(src_file, tmpdir)
            log_config(tmpdir)

        yield new_path

    yield _isolation


def run_process_capture_logs(command, cwd, name="", process_holder=None) -> None:
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        cwd=cwd,
    )
    assert process, "Process creation failed"
    assert process.stdout, "Could not get stdout"

    if process_holder != None:
        process_holder[name] = process

    for line in process.stdout:
        logger.info(line.strip())

    process.wait()


def __get_parameters():
    texts = [
        "The quick brown fox jumps over the lazy dog",
        "Dość błazeństw, żrą mój pęk luźnych fig",
    ]
    examples = [
        "", # default
        "adamws-config",
        "custom-keycap-asset",
        "customized-pok3r-theme",
        "custom-split-layout",
    ]
    test_params = []
    # not interested in all combinations

    test_params.append(pytest.param(texts[0], examples[0]))
    test_params.append(pytest.param(texts[1], examples[0]))
    test_params.append(pytest.param(texts[0], examples[1]))
    test_params.append(pytest.param(texts[0], examples[2]))
    test_params.append(pytest.param(texts[0], examples[3]))
    test_params.append(pytest.param(texts[1], examples[4]))

    return test_params


@pytest.mark.parametrize(
    "text,example", __get_parameters()
)
def test_record_and_render(app_isolation, text: str, example) -> None:
    with app_isolation(example) as app:
        app_dir = Path(app).parent
        processes = {}

        thread = threading.Thread(
            target=run_process_capture_logs,
            args=([app, "--record", "events.bin"], app_dir, "klawa", processes,)
        )
        thread.start()
        time.sleep(2)

        subprocess.run(["xdotool", "type", "--delay", "400", text])

        process = processes.get("klawa")
        if process and process.poll() is None:
            os.kill(process.pid, signal.SIGTERM)

        thread.join()

        args = [app, "--replay", "events.bin", "--render", "output.webm"]
        run_process_capture_logs(args, app_dir)
