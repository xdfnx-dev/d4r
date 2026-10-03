"""Recompile private K output IR with isolated LLVM 22 scheduling hints.

Only the selected kernel's code-generation attributes change. Strict floating
point operations, denormal modes, wave size and CU/WGP mode remain untouched.
No runtime installation is performed. Inputs and resulting objects stay private.
"""
import argparse
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys

from build_native_texture import require_code_object_target

KERNELS = tuple('hiluma_engine_output_' + variant + '_max_v2_rel' for variant in
                ('depthinv_mvlo_hdr', 'depthreg_mvhi_ldr'))
SCHEDULERS = ('default', 'max-ilp', 'max-memory-clause', 'iterative-ilp',
              'iterative-minreg', 'iterative-maxocc')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def change_attributes(ir, kernel, scheduler, max_vgpr):
    definition = re.search(r'^define amdgpu_kernel [^\n]*@' + re.escape(kernel) +
                           r'\([^\n]*#(\d+)\s*\{', ir, re.M)
    if not definition:
        raise RuntimeError('Missing selected kernel definition')
    attribute = re.search(r'^attributes #' + definition[1] + r' = \{([^\n]*)\}$', ir, re.M)
    if not attribute or 'strictfp' not in attribute[1] or '"denormal-fp-math"="ieee"' not in attribute[1]:
        raise RuntimeError('Require the strict Windows-validated FP16 output IR')
    if '+wavefrontsize32,-wavefrontsize64' not in attribute[1]:
        raise RuntimeError('Require the original wave32 code-generation mode')
    values = attribute[1]
    updates = {}
    if scheduler != 'default':
        updates['amdgpu-sched-strategy'] = scheduler
    if max_vgpr:
        updates['amdgpu-num-vgpr'] = str(max_vgpr)
    if not updates:
        return ir
    for key, value in updates.items():
        values = re.sub(r'"' + key + r'"="[^"]*"\s*', '', values)
        values += f' "{key}"="{value}"'
    # Give this kernel its own group; never change helper functions sharing the
    # original group. The function body and every original FP attribute remain.
    number = 1 + max(map(int, re.findall(r'^attributes #(\d+) =', ir, re.M)))
    start, end = definition.span(1)
    return ir[:start] + str(number) + ir[end:] + f'\nattributes #{number} = {{{values}}}\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('source-directory', 'llvm-bin', 'hip-root', 'dlss-dll', 'output-directory'):
        parser.add_argument('--' + name, required=True, type=lambda s: pathlib.Path(s).resolve())
    parser.add_argument('--scheduler', choices=SCHEDULERS, default='default')
    parser.add_argument('--max-vgpr', type=int, default=0)
    parser.add_argument('--kernels', nargs='+', choices=KERNELS, default=KERNELS)
    args = parser.parse_args()
    if args.max_vgpr and not 64 <= args.max_vgpr <= 256:
        parser.error('max-vgpr must be 0 (unchanged) or 64..256')
    if len(set(args.kernels)) != len(args.kernels):
        parser.error('duplicate kernels')
    llc = args.llvm_bin / 'llc.exe'
    linker = args.hip_root / 'bin/ld.lld.exe'
    readobj = args.hip_root / 'bin/llvm-readobj.exe'
    source_info = json.loads((args.source_directory / 'build-info.json').read_text(encoding='utf-8-sig'))
    if (source_info.get('architecture') != 'gfx1201' or not source_info.get('accuracy') or
            source_info.get('nativeFP8') or not source_info.get('privateNvidiaDerivedCode') or
            source_info.get('dlssSha256', '').lower() != sha(args.dlss_dll)):
        raise RuntimeError('Source provenance does not match strict gfx1201 K and the local DLSS DLL')
    mode = source_info.get('shaderMode')
    if mode not in ('cu', 'wgp'):
        raise RuntimeError('Source provenance must explicitly record its CU/WGP mode')
    environment = os.environ.copy()
    environment['PATH'] = str(args.llvm_bin) + os.pathsep + environment['PATH']
    version = subprocess.check_output([str(llc), '--version'], env=environment).decode(errors='replace')
    if 'LLVM version 22.' not in version:
        raise RuntimeError('Use the matching audited ZLUDA LLVM 22 build; other versions are unvalidated')
    output = args.output_directory
    output.mkdir(parents=True, exist_ok=False)
    info = dict(architecture='gfx1201', accuracy=True, nativeFP8=False,
                privateNvidiaDerivedCode=True, experimental=True, shaderMode=mode, scheduler=args.scheduler,
                maxVgpr=args.max_vgpr, dlssSha256=sha(args.dlss_dll),
                validation='pending; do not install before full-frame exact comparison',
                compiler=str(llc), compilerSha256=sha(llc), compilerVersion=version,
                linkerSha256=sha(linker), source=source_info, objects={}, commands=[])

    def run(label, command):
        with (output / (label + '.stdout.log')).open('wb') as stdout, \
                (output / (label + '.stderr.log')).open('wb') as stderr:
            result = subprocess.run(list(map(str, command)), env=environment,
                                    stdout=stdout, stderr=stderr, timeout=180)
        info['commands'].append(dict(label=label, command=list(map(str, command)), exitCode=result.returncode))
        if result.returncode:
            raise RuntimeError(f'{label} failed ({result.returncode}); preserved logs in {output}')

    try:
        for kernel in args.kernels:
            original = args.source_directory / kernel_name_file(kernel)
            if sha(args.source_directory / (kernel + '.hsaco')) != source_info['objects'][kernel + '.hsaco']:
                raise RuntimeError('Source object differs from its build provenance')
            ir = original.read_text()
            edited = output / (kernel + '.ll')
            edited.write_text(change_attributes(ir, kernel, args.scheduler, args.max_vgpr))
            object_file = output / (kernel + '.o')
            code_object = output / (kernel + '.hsaco')
            run(kernel + '.compile', [llc, '-O=3', '-march=amdgcn', '-mcpu=gfx1201',
                                     '-mattr=+wavefrontsize32,-wavefrontsize64,' +
                                     ('-cumode' if mode == 'wgp' else '+cumode'),
                                     '-amdhsa-code-object-version=5', '-filetype=obj', edited, '-o', object_file])
            run(kernel + '.link', [linker, '-shared', object_file, '-o', code_object])
            require_code_object_target(code_object, 'gfx1201')
            run(kernel + '.metadata', [readobj, '--notes', code_object])
            info['objects'][code_object.name] = sha(code_object)
            info.setdefault('inputIrSha256', {})[kernel] = sha(original)
        repo = pathlib.Path(__file__).resolve().parents[2]
        run('manifest', [sys.executable, repo / 'kernels/tools/kernel_manifest.py', output, args.dlss_dll])
        print(f'Compiled PRIVATE gfx1201 output experiment: {output}; numerical validation pending')
    except Exception as error:
        info['error'] = str(error)
        raise
    finally:
        (output / 'build-info.json').write_text(json.dumps(info, indent=2) + '\n')


def kernel_name_file(kernel):
    return pathlib.Path('work-' + kernel) / 'emitted/opt.ll'


if __name__ == '__main__':
    main()
