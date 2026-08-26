
import pytest
import subprocess
import testinfra


# scope='session' uses the same container for all the tests;
# scope='function' uses a new container per test function.
@pytest.fixture(scope='session')
def host(request):
    # build local ./Dockerfile
    subprocess.check_call(['docker', 'build', '-t', 'tmp_image', '.'])
    # run a container
    docker_id = subprocess.check_output(
        ['docker', 'run', '-d', 'tmp_image', '/bin/bash', '-c', 'while true; do sleep 1; done']).decode().strip()
    # return a testinfra connection to the container
    yield testinfra.get_host("docker://" + docker_id)
    # at the end of the test suite, destroy the container
    subprocess.check_call(['docker', 'rm', '-f', docker_id])


def test_image(host):
    # 'host' now binds to the container
    clis = ["aws", "curl", "dd", "awk", "bc"]
    for cli in clis:
        command = f"which {cli}"
        result = host.run(command)
        assert result.rc == 0, f"Бинарный файл '{cli}' не найден " \
                               f"в системном пути ($PATH) на хосте."
