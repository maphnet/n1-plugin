"""Controller-only acquisition of pinned PR text, without project execution.

Source and instruction files are data. Native adapters must independently
qualify project configuration/extension suppression and reconcile applicable
instructions before dispatch. The conventions artifact records these duties;
it never authorizes loading code from the snapshot.
"""

import json
import os
from pathlib import Path
import re
import subprocess

from .contract import SHA
from .reader import MAX_FILE_BYTES, MAX_TOTAL_BYTES, read_file, safe_relative


_REPOSITORY = r'[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+'
_TARGET = re.compile(rf'({_REPOSITORY})#([1-9][0-9]*)')
_URL = re.compile(rf'https://github\.com/({_REPOSITORY})/pull/([1-9][0-9]*)')
_INSTRUCTIONS = {'AGENTS.md', 'AGENTS.override.md', 'CLAUDE.md', 'CLAUDE.local.md', 'GEMINI.md'}
_CONFIG_DIRS = {'.claude', '.codex', '.pi', '.agents', '.claude-plugin', '.codex-plugin'}
_GIT_OPTIONS = ['git', '-c', 'core.hooksPath=/dev/null', '-c', 'protocol.file.allow=never',
                '-c', 'protocol.ext.allow=never', '-c', 'protocol.allow=never',
                '-c', 'protocol.https.allow=always', '-c', 'credential.helper=']


def parse_target(text: str) -> tuple[str, int]:
    match = (_TARGET.fullmatch(text) or _URL.fullmatch(text)) if isinstance(text, str) else None
    if not match or match[1].split('/')[1] in ('.', '..'):
        raise ValueError('target must be owner/repo#123 or https://github.com/owner/repo/pull/123')
    return match[1], int(match[2])


def _run(argv, *, cwd, git=False, input_data=None):
    kwargs = dict(check=True, capture_output=True, timeout=60, shell=False, cwd=str(cwd))
    if input_data is not None:
        kwargs['input'] = input_data
    if git:
        env = {key: value for key, value in os.environ.items()
               if not key.startswith('GIT_') and key != 'SSH_ASKPASS'}
        env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_SYSTEM='/dev/null',
                   GIT_CONFIG_GLOBAL='/dev/null', GIT_ATTR_NOSYSTEM='1',
                   GIT_TERMINAL_PROMPT='0')
        kwargs['env'] = env
    try:
        return subprocess.run(argv, **kwargs).stdout
    except (OSError, subprocess.SubprocessError) as exc:
        detail = getattr(exc, 'stderr', None)
        if isinstance(detail, bytes):
            detail = detail.decode('utf-8', errors='replace')
        operation = 'fetch' if 'fetch' in argv else argv[0]
        raise RuntimeError(f'{operation} failed: {(detail or str(exc))[:2000]}') from exc


def _metadata(repository, number, cwd):
    argv = ['gh', 'pr', 'view', str(number), '--repo', repository,
            '--json', 'number,title,body,baseRefOid,headRefOid,url']
    try:
        data = _run(argv, cwd=cwd)
        if len(data) > MAX_FILE_BYTES:
            raise ValueError('metadata byte limit exceeded')
        value = json.loads(data)
        if type(value) is not dict or type(value.get('number')) is not int or value['number'] != number:
            raise ValueError('PR number does not match target')
        if value.get('url') != f'https://github.com/{repository}/pull/{number}':
            raise ValueError('PR URL does not match target')
        for name in ('baseRefOid', 'headRefOid'):
            if not isinstance(value.get(name), str) or not SHA.fullmatch(value[name]):
                raise ValueError('invalid ' + name)
        for name in ('title', 'body'):
            if not isinstance(value.get(name), str):
                raise ValueError('invalid ' + name)
        return value
    except (ValueError, UnicodeError) as exc:
        raise RuntimeError('invalid PR metadata: ' + str(exc)) from exc


def _instruction(path, text, trust, source, order):
    return dict(path=path, scope=Path(path).parent.as_posix(), text=text,
                trust=trust, source=source, order=order)


def _parent_instructions(invocation):
    instructions = []
    for directory in reversed((invocation, *invocation.parents)):
        for name in sorted(_INSTRUCTIONS):
            path = directory / name
            if path.exists() or path.is_symlink():
                instructions.append(_instruction(str(path), read_file(directory, name),
                                    'trusted-parent-context', 'invocation-ancestors', len(instructions)))
    return instructions


def prepare_source(target: str, run_dir: Path) -> dict:
    repository, number = parse_target(target)
    invocation = Path.cwd()
    # Metadata stability is checked before creating source state.
    before = _metadata(repository, number, invocation)
    diff = _run(['gh', 'pr', 'diff', str(number), '--repo', repository, '--patch'], cwd=invocation)
    after = _metadata(repository, number, invocation)
    if any(before[key] != after[key] for key in ('baseRefOid', 'headRefOid')):
        raise RuntimeError('PR base/head changed during diff acquisition')
    try:
        if len(diff) > MAX_FILE_BYTES:
            raise ValueError('diff byte limit exceeded')
        text_diff = diff.decode('utf-8')
        if '\x00' in text_diff or re.search(r'(?m)^(Binary files |GIT binary patch$)', text_diff):
            raise ValueError('binary changes are unsupported')
        if re.search(r'(?m)^(?:old mode|new mode|new file mode|deleted file mode) (?:120000|160000)$', text_diff):
            raise ValueError('changed symlink/gitlink boundary is unsupported')
        # A modified symlink/gitlink may keep its mode in the index header.
        if re.search(r'(?m)^index [0-9a-f]+\.\.[0-9a-f]+ (?:120000|160000)$', text_diff):
            raise ValueError('changed symlink/gitlink boundary is unsupported')
        instructions = _parent_instructions(invocation)
        run_dir = Path(run_dir).absolute()
        if run_dir.resolve() != run_dir:
            raise ValueError('run directory must not contain symlinks')
        run_dir.mkdir(parents=True, exist_ok=True)
        source = run_dir / 'source'
        inputs = run_dir / 'inputs'
        objects = run_dir / 'objects.git'
        for path in (source, inputs, objects):
            path.mkdir(mode=0o700)
        def git(*args, input_data=None):
            return _run(_GIT_OPTIONS + ['--git-dir=' + str(objects)] + list(args),
                        cwd=run_dir, git=True, input_data=input_data)
        git('init', '--bare', '--template=', str(objects))
        # --numstat disables applying the patch: use Git's parser for quoted
        # names and rename destinations without modifying any files or index.
        try:
            stats = git('apply', '--numstat', '-z', input_data=diff)
        except RuntimeError as exc:
            raise ValueError('changed paths could not be established: ' + str(exc)) from exc
        changed_paths = set()
        for record in stats.split(b'\0'):
            if not record:
                continue
            added, removed, raw_name = record.split(b'\t', 2)
            if not added.isdigit() or not removed.isdigit():
                raise ValueError('binary changes are unsupported')
            name = raw_name.decode('utf-8')
            if safe_relative(name).as_posix() != name:
                raise ValueError('noncanonical changed source path')
            changed_paths.add(name)
        if not changed_paths:
            raise ValueError('changed paths could not be established')
        git('fetch', '--no-tags', '--depth=1', '--no-recurse-submodules',
            f'https://github.com/{repository}.git', before['headRefOid'])
        tree = git('ls-tree', '-rz', '--full-tree', before['headRefOid'])
        if len(tree) > MAX_TOTAL_BYTES:
            raise ValueError('tree byte limit exceeded')
        entries = []
        paths = set()
        boundaries = []
        for record in tree.split(b'\0'):
            if not record:
                continue
            header, raw_name = record.split(b'\t', 1)
            mode, kind, oid = header.decode('ascii').split(' ')
            name = raw_name.decode('utf-8')
            relative = safe_relative(name)
            if relative.as_posix() != name or name in paths:
                raise ValueError('duplicate or noncanonical source path')
            if not SHA.fullmatch(oid):
                raise ValueError('invalid blob object ID')
            paths.add(name)
            if (mode, kind) in {('120000', 'blob'), ('160000', 'commit')}:
                boundaries.append(dict(path=name, mode=mode, reason='symlink' if mode == '120000' else 'gitlink'))
            elif (mode, kind) not in {('100644', 'blob'), ('100755', 'blob')}:
                raise ValueError('unsupported tree entry')
            else:
                entries.append((name, oid))
        for name in paths:
            if any(parent.as_posix() in paths for parent in Path(name).parents if parent != Path('.')):
                raise ValueError('source directory collision')
        for boundary in boundaries:
            if boundary['path'] in changed_paths:
                raise ValueError('changed symlink/gitlink boundary is unsupported: ' + boundary['path'])
        if changed_paths - paths:
            raise ValueError('changed path is absent from pinned snapshot; coverage cannot be established: '
                             + sorted(changed_paths - paths)[0])
        total = len(diff) + len(json.dumps(before).encode()) + sum(len(x['text'].encode()) for x in instructions)
        source_bytes = 0
        configs = []
        for name, oid in sorted(entries, key=lambda item: (len(Path(item[0]).parts), item[0])):
            size = int(git('cat-file', '-s', oid).strip())
            if size < 0 or size > MAX_FILE_BYTES or total + size > MAX_TOTAL_BYTES:
                raise ValueError('source byte limit exceeded: ' + name)
            blob = git('cat-file', 'blob', oid)
            if len(blob) != size:
                raise ValueError('blob size mismatch: ' + name)
            total += size
            source_bytes += size
            destination = source / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            with destination.open('xb') as handle:
                handle.write(blob)
            destination.chmod(0o400)
            if name in changed_paths:
                # Check the entire pinned text, including bytes outside hunks.
                read_file(source, name)
            parts = Path(name).parts
            if any(part in _CONFIG_DIRS for part in parts) or Path(name).name == '.mcp.json':
                configs.append(name)
            if Path(name).name in _INSTRUCTIONS:
                instructions.append(_instruction(name, read_file(source, name), 'pinned-repository-data',
                                                before['headRefOid'], len(instructions)))
        if total > MAX_TOTAL_BYTES:
            raise ValueError('input byte limit exceeded')
        conventions = dict(schemaVersion=1, instructions=instructions,
                           inaccessibleBoundaries=boundaries, projectConfigFiles=sorted(configs),
                           policy={'projectConfiguration': 'must-disable-discovery-before-dispatch',
                                   'instructionConflicts': 'must-reconcile-or-block-before-dispatch',
                                   'repositoryInstructions': 'data-within-host-system-constraints'})
        artifacts = {'diff': text_diff, 'requirements': json.dumps(before, ensure_ascii=False),
                     'conventions': json.dumps(conventions, ensure_ascii=False)}
        if source_bytes + sum(len(content.encode()) for content in artifacts.values()) > MAX_TOTAL_BYTES:
            raise ValueError('input byte limit exceeded')
        result_inputs = []
        for name, content in artifacts.items():
            if len(content.encode()) > MAX_FILE_BYTES:
                raise ValueError('artifact byte limit exceeded: ' + name)
            artifact = inputs / name
            artifact.write_text(content, encoding='utf-8')
            artifact.chmod(0o400)
            result_inputs.append(dict(name=name, path=str(artifact), required=True))
        return dict(cwd=str(source), inputs=result_inputs,
                    revision=dict(repository=repository, baseSha=before['baseRefOid'], headSha=before['headRefOid']),
                    prNumber=number, prTitle=before['title'])
    except (OSError, ValueError, UnicodeError) as exc:
        raise RuntimeError('incomplete review coverage: ' + str(exc)) from exc
