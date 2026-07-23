subdir('helpers')

# Prefer a local tests/.venv when present (see tests/README.md); else PATH.
pytest = find_program(
  'pytest',
  dirs: [meson.current_source_dir() / '.venv' / 'bin'],
  required: false,
  disabler: true,
)

tests_dir = meson.current_source_dir()

test_env = environment()
test_env.set('KAKI_BIN', kaki.full_path())
test_env.set('KAKI_SOURCE_ROOT', meson.project_source_root())
test_env.set('KAKI_DOWNLOAD_CLI', download_cli.full_path())
test_env.set('KAKI_REMOTE_CLI', remote_cli.full_path())
# Ensure the venv (if any) wins for python imports when pytest spawns.
venv_bin = meson.current_source_dir() / '.venv' / 'bin'
test_env.prepend('PATH', venv_bin)

pytest_args = ['-q', '--tb=short']

test('pytest-unit', pytest,
  args: pytest_args + [tests_dir / 'unit'],
  env: test_env,
  suite: 'unit',
  workdir: meson.project_source_root(),
  depends: [kaki],
)

test('pytest-integration', pytest,
  args: pytest_args + [tests_dir / 'integration'],
  env: test_env,
  suite: 'integration',
  workdir: meson.project_source_root(),
  depends: [kaki, download_cli, remote_cli],
  is_parallel: false,
  timeout: 120,
)

test('pytest-ui', pytest,
  args: pytest_args + ['-m', 'ui', tests_dir / 'ui'],
  env: test_env,
  suite: 'ui',
  workdir: meson.project_source_root(),
  depends: [kaki],
  is_parallel: false,
  timeout: 180,
)

test('pytest-network', pytest,
  args: pytest_args + ['-m', 'network', tests_dir / 'network'],
  env: test_env,
  suite: 'network',
  workdir: meson.project_source_root(),
  timeout: 60,
)
