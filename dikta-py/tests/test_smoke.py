from dikta import __version__
from dikta.cli import main


def test_version_string() -> None:
    assert __version__ == "0.1.0"


def test_cli_version_flag(capsys) -> None:
    assert main(["--version"]) == 0
    assert capsys.readouterr().out.strip() == "dikta 0.1.0"
