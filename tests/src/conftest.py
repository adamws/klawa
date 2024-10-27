import glob
import os
import shutil
from pathlib import Path

import pytest


def pytest_addoption(parser) -> None:
    parser.addoption(
        "--app-path",
        action="store",
        help="Path to klawa executable",
        default=False,
    )


@pytest.fixture(scope="session")
def app_path(request) -> Path:
    app_path = request.config.getoption("--app-path")
    assert app_path, "App path is required"
    return Path(os.path.realpath(app_path))


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item, call):
    pytest_html = item.config.pluginmanager.getplugin("html")
    outcome = yield
    report = outcome.get_result()
    extras = getattr(report, "extras", [])

    if report.when == "call" and not report.skipped:
        artifact_dir = Path(item.config.option.htmlpath).parent
        webm_count = len(glob.glob(f"{artifact_dir}/*webm"))
        if tmpdir := item.funcargs.get("tmpdir"):
            videos = glob.glob(f"{tmpdir}/*webm")
            for f in videos:
                dest = shutil.copy(f, artifact_dir / f"output{webm_count}.webm")
                dest = Path(dest).relative_to(artifact_dir)
                html = f'<video controls autoplay loop><source src="{dest}" type="video/webm"></video>'
                extras.append(pytest_html.extras.html(html))
        report.extras = extras
