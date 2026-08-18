#requires -Modules Pester

<#
.SYNOPSIS
    Pester tests for the vsenv function in vbam-builder.psm1.

.DESCRIPTION
    Run with:

        pwsh -noprofile -command 'invoke-pester ./vbam-builder.tests.ps1 -output detailed'

    vcvarsall.bat is mocked, so these tests do not need a working Visual
    Studio installation, but vsenv itself is only defined when one is
    found, so everything is skipped when it is not.
#>

# ── the module has to be loaded at discovery time for -skip ─────────
$script:vbam = import-module "$PSScriptRoot/vbam-builder.psm1" -force `
    -disablenamechecking -passthru

$script:has_vsenv = [bool](& $script:vbam { get-command vsenv -ea ignore })

beforeall {
    # ── snapshot environment so tests cannot pollute each other ──────
    $script:env_snap = @{}
    gci env: | %{ $script:env_snap[$_.name] = $_.value }

    # ── temp directory for the mock vcvarsall and test files ─────────
    $script:temp_dir = join-path ([system.io.path]::gettemppath()) `
        "vbam-builder-tests-$PID"
    ni -itemtype directory $script:temp_dir -force | out-null

    # ── mock vcvarsall.bat ──────────────────────────────────────────
    # Calls a generated response.bat that sets env vars and echoes
    # banner lines, so the subsequent `&& set` (from vsenv) outputs
    # the correct merged environment.
    $script:mock_vcvarsall = join-path $script:temp_dir 'vcvarsall.bat'
    $script:mock_response  = join-path $script:temp_dir 'vcvarsall_response.bat'
    $script:mock_exitcode  = join-path $script:temp_dir 'vcvarsall_exitcode.txt'
    $script:mock_args_log  = join-path $script:temp_dir 'vcvarsall_args.txt'

    @"
@echo off
echo %* > "$($script:mock_args_log)"
if not exist "$($script:mock_exitcode)" goto :RUN
set /p EXITCODE=<"$($script:mock_exitcode)"
if not "%EXITCODE%"=="0" exit /b %EXITCODE%
:RUN
if exist "$($script:mock_response)" call "$($script:mock_response)"
"@ | set-content $script:mock_vcvarsall -encoding ascii

    function script:set_mock_output {
        param([string[]]$lines = @(), [int]$exit_code = 0)

        if ($lines) {
            # Convert response lines into a bat file: VAR=value lines
            # become `set` commands, non-VAR lines become `echo` commands.
            $bat = @('@echo off') + @($lines | %{
                if ($_ -match '^[A-Za-z_][A-Za-z_0-9]*=') { "set `"$_`"" }
                else { "echo $_" }
            })
            $bat | set-content $script:mock_response -encoding ascii
        }
        elseif (test-path $script:mock_response) {
            ri $script:mock_response
        }
        "$exit_code" | set-content $script:mock_exitcode -encoding ascii
    }

    function script:get_mock_args {
        if (test-path $script:mock_args_log) {
            (gc $script:mock_args_log -raw).trim()
        }
    }

    # ── build a standard mock vcvarsall response for a given arch ───
    function script:new_vcvarsall_response {
        param(
            [string]$arch          = 'x64',
            [string]$vs_root       = 'C:\Program Files\Microsoft Visual Studio\18\Community',
            [string]$sdk_bin       = 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0',
            [string]$tools_version = '14.50.35717'
        )

        $host_arch = 'x64'

        $target_arch = if ($arch -iin 'x64','amd64') { 'x64' }
                       elseif ($arch -ieq 'x86')     { 'x86' }
                       elseif ($arch -ieq 'arm64')    { 'arm64' }
                       else { $arch }

        $msvc_bin = "$vs_root\VC\Tools\MSVC\$tools_version\bin\Host${host_arch}\${target_arch}"

        $vs_path_entries = @(
            $msvc_bin
            "$vs_root\Common7\IDE\VC\VCPackages"
            "$vs_root\Common7\IDE\CommonExtensions\Microsoft\TestWindow"
            "$vs_root\MSBuild\Current\bin\Roslyn"
            'C:\Program Files (x86)\Microsoft SDKs\Windows\v10.0A\bin\NETFX 4.8 Tools\x64'
            'C:\Program Files (x86)\HTML Help Workshop'
            "$sdk_bin\${target_arch}"
            'C:\Program Files (x86)\Windows Kits\10\bin\x64'
            "$vs_root\MSBuild\Current\Bin\amd64"
            'C:\WINDOWS\Microsoft.NET\Framework64\v4.0.30319'
            "$vs_root\Common7\IDE"
            "$vs_root\Common7\Tools"
            "$vs_root\VC\vcpkg"
        )

        # Use %Path% so cmd.exe expands the actual inherited PATH at
        # runtime — this respects any stripping vsenv does before launch.
        $vs_path_joined = $vs_path_entries -join ';'

        @(
            "[vcvarsall.bat] Environment initialized for: '${target_arch}'"
            "Path=%Path%;$vs_path_joined"
            "INCLUDE=$vs_root\VC\Tools\MSVC\$tools_version\include;$sdk_bin\..\..\..\include\10.0.26100.0\ucrt;$sdk_bin\..\..\..\include\10.0.26100.0\shared;$sdk_bin\..\..\..\include\10.0.26100.0\um"
            "LIB=$vs_root\VC\Tools\MSVC\$tools_version\lib\${target_arch};$sdk_bin\..\..\..\lib\10.0.26100.0\ucrt\${target_arch};$sdk_bin\..\..\..\lib\10.0.26100.0\um\${target_arch}"
            "LIBPATH=$vs_root\VC\Tools\MSVC\$tools_version\lib\${target_arch}"
            "EXTERNAL_INCLUDE=$vs_root\VC\Tools\MSVC\$tools_version\include"
            "VSINSTALLDIR=$vs_root\"
            "VCToolsVersion=$tools_version"
            "VSCMD_ARG_HOST_ARCH=$host_arch"
            "VSCMD_ARG_TGT_ARCH=$target_arch"
            "__VSCMD_PREINIT_PATH=$env:Path"
        )
    }

    # ── module internals ────────────────────────────────────────────
    # vsenv and the env helpers are private to the module, so they are
    # called in its session state.
    $script:vbam = get-module vbam-builder

    function script:vsenv     { & $script:vbam { vsenv @args }     @args }
    function script:save_env  { & $script:vbam { save_env }  }
    function script:restore_env { & $script:vbam { restore_env } }

    function script:get_vsenv_state {
        & $script:vbam { $script:vsenv_state }
    }

    function script:get_vsenv_vcpkg_in_path {
        & $script:vbam { $script:vsenv_vcpkg_in_path }
    }

    function script:reset_vsenv {
        try { vsenv -unload } catch {}
        & $script:vbam {
            $script:vsenv_state = $null
            $script:vsenv_vcpkg_in_path = $null
        }
    }

    function script:invoke_vsenv {
        param([string]$arch = 'x64', [string]$toolkit, [string[]]$extra_lines = @())

        $response = new_vcvarsall_response -arch $arch
        if ($extra_lines) { $response = $response + $extra_lines }
        set_mock_output -lines $response
        if ($toolkit) { vsenv $arch $toolkit }
        else          { vsenv $arch }
    }

    # ── inject the mock vcvarsall into the module ───────────────────
    # No $has_vsenv check here, that is set during discovery and is not
    # visible in this scope, and the describe below is skipped anyway.
    & $script:vbam {
        $script:vcvarsall = resolve-path $args[0]
    } $script:mock_vcvarsall
}

afterall {
    ri env:* -force -ea ignore
    $script:env_snap.getenumerator() | %{
        si -literalpath "env:$($_.key)" $_.value
    }

    if ($script:temp_dir -and (test-path $script:temp_dir)) {
        ri $script:temp_dir -recurse -force -ea ignore
    }
}

# ════════════════════════════════════════════════════════════════════════
#  vsenv
# ════════════════════════════════════════════════════════════════════════
describe 'vsenv' -skip:(-not $script:has_vsenv) {

    beforeall {
        $script:vsenv_env_snap = @{}
        gci env: | %{ $script:vsenv_env_snap[$_.name] = $_.value }
    }

    beforeeach {
        ri env:* -force -ea ignore
        $script:vsenv_env_snap.getenumerator() | %{
            si -literalpath "env:$($_.key)" $_.value
        }
        reset_vsenv
    }

    # ── Initial Load ────────────────────────────────────────────────
    describe 'Initial Load' {

        it 'adds VS tool paths to $env:Path' {
            invoke_vsenv -arch x64
            $env:Path | should -match 'Microsoft Visual Studio'
            $env:Path | should -match 'MSVC'
        }

        it 'sets INCLUDE from vcvarsall output' {
            invoke_vsenv -arch x64
            $env:INCLUDE | should -not -benullorempty
            $env:INCLUDE | should -match 'MSVC'
        }

        it 'sets LIB from vcvarsall output' {
            invoke_vsenv -arch x64
            $env:LIB | should -not -benullorempty
            $env:LIB | should -match 'MSVC'
        }

        it 'sets LIBPATH from vcvarsall output' {
            invoke_vsenv -arch x64
            $env:LIBPATH | should -not -benullorempty
        }

        it 'sets EXTERNAL_INCLUDE from vcvarsall output' {
            invoke_vsenv -arch x64
            $env:EXTERNAL_INCLUDE | should -not -benullorempty
        }

        it 'sets scalar env vars like VSINSTALLDIR' {
            invoke_vsenv -arch x64
            $env:VSINSTALLDIR | should -not -benullorempty
            $env:VSINSTALLDIR | should -match 'Microsoft Visual Studio'
        }

        it 'records vsenv_state' {
            invoke_vsenv -arch x64
            $state = get_vsenv_state
            $state | should -not -benullorempty
            $state.saved_lists | should -not -benullorempty
            $state.vars | should -not -benullorempty
        }

        it 'appends VS entries AFTER baseline PATH entries' {
            $first_baseline = ($env:Path -split ';')[0]
            invoke_vsenv -arch x64
            $entries = $env:Path -split ';'
            $base_idx = [array]::indexof($entries, $first_baseline)
            $vs_idx = 0
            for ($i = 0; $i -lt $entries.count; $i++) {
                if ($entries[$i] -match 'Microsoft Visual Studio') { $vs_idx = $i; break }
            }
            $vs_idx | should -begreaterthan $base_idx
        }

        it 'uses default arch when none specified' {
            set_mock_output -lines (new_vcvarsall_response -arch x64)
            vsenv
            get_mock_args | should -not -benullorempty
        }
    }

    # ── Unload ──────────────────────────────────────────────────────
    describe 'Unload' {

        it 'removes the VS entries from PATH' {
            $baseline = $env:Path
            invoke_vsenv -arch x64
            $env:Path | should -not -be $baseline
            vsenv -unload
            $env:Path | should -not -match '\\Microsoft Visual Studio\\'
        }

        it 'restores INCLUDE to pre-vsenv value' {
            $before = $env:INCLUDE
            invoke_vsenv -arch x64
            vsenv -unload
            $env:INCLUDE | should -be $before
        }

        it 'restores LIB to pre-vsenv value' {
            $before = $env:LIB
            invoke_vsenv -arch x64
            vsenv -unload
            $env:LIB | should -be $before
        }

        it 'removes env vars that did not exist before vsenv' {
            ri env:VSINSTALLDIR -ea ignore
            invoke_vsenv -arch x64
            $env:VSINSTALLDIR | should -not -benullorempty
            vsenv -unload
            $env:VSINSTALLDIR | should -benullorempty
        }

        it 'clears vsenv_state to null' {
            invoke_vsenv -arch x64
            get_vsenv_state | should -not -benullorempty
            vsenv -unload
            get_vsenv_state | should -benullorempty
        }

        it 'is idempotent' {
            invoke_vsenv -arch x64
            vsenv -unload
            { vsenv -unload } | should -not -throw
        }
    }

    # ── Session PATH Additions ──────────────────────────────────────
    # vsenv subtracts the entries vcvarsall added rather than restoring
    # the PATH baseline it captured when it loaded, so entries added to
    # PATH in between are kept.
    describe 'Session PATH Additions' {

        it 'keeps an entry added after the load across a reload' {
            $new_dir = join-path $script:temp_dir 'added-by-hand'

            invoke_vsenv -arch x64
            $env:Path = $new_dir + ';' + $env:Path

            invoke_vsenv -arch x64

            ($env:Path -split ';') | should -contain $new_dir
        }

        it 'keeps an entry added after the load across an arch switch' {
            $new_dir = join-path $script:temp_dir 'added-before-switch'

            invoke_vsenv -arch x64
            $env:Path = $new_dir + ';' + $env:Path

            invoke_vsenv -arch arm64

            ($env:Path -split ';') | should -contain $new_dir
            $env:Path | should -match 'arm64'
        }

        it 'keeps an entry added after the load across an unload' {
            $new_dir = join-path $script:temp_dir 'added-before-unload'

            invoke_vsenv -arch x64
            $env:Path = $new_dir + ';' + $env:Path

            vsenv -unload

            ($env:Path -split ';') | should -contain $new_dir
            $env:Path | should -not -match '\\Microsoft Visual Studio\\'
        }

        it 'records the PATH entries vcvarsall added' {
            invoke_vsenv -arch x64

            $added = (get_vsenv_state).vcvarsall_additions['PATH']

            $added | should -not -benullorempty
            $added['C:\Program Files\Microsoft Visual Studio\18\Community\Common7\IDE'] |
                should -betrue
        }

        it 'does not record VCPKG_ROOT as an addition' {
            $env:VCPKG_ROOT = join-path $script:temp_dir 'vcpkg-additions'
            ni -itemtype directory $env:VCPKG_ROOT -force | out-null

            invoke_vsenv -arch x64

            $added = (get_vsenv_state).vcvarsall_additions['PATH']

            $added[$env:VCPKG_ROOT.trimend('/\')] | should -not -betrue
        }

        it 'still strips VS entries inherited from a parent shell' {
            # Entries that vcvarsall did not add in this session are not in
            # the record, so unloading falls back to matching them.
            invoke_vsenv -arch x64
            $env:Path = 'C:\Program Files\Microsoft Visual Studio\18\Community\Inherited;' +
                $env:Path

            vsenv -unload

            $env:Path | should -not -match '\\Microsoft Visual Studio\\'
        }

        it 'does not duplicate entries across repeated loads' {
            # The first load also absorbs any VS entries inherited from a
            # parent shell, so compare once the environment has settled.
            invoke_vsenv -arch x64
            invoke_vsenv -arch x64
            $once = $env:Path

            invoke_vsenv -arch x64
            invoke_vsenv -arch x64

            $env:Path | should -be $once

            $entries = $env:Path -split ';' | ? length | %{ $_.trimend('/\') }
            ($entries | select -unique).count | should -be $entries.count
        }
    }

    # ── Unload then Reload ──────────────────────────────────────────
    describe 'Unload then Reload' {

        it 'produces identical VS entries to a fresh load' {
            invoke_vsenv -arch x64
            $first_vs = ($env:Path -split ';') | ? { $_ -match 'Microsoft Visual Studio' }

            vsenv -unload
            invoke_vsenv -arch x64
            $reload_vs = ($env:Path -split ';') | ? { $_ -match 'Microsoft Visual Studio' }

            ($reload_vs -join ';') | should -be ($first_vs -join ';')
        }

        it 'does not accumulate entries' {
            invoke_vsenv -arch x64
            $first_count = ($env:Path -split ';').count

            vsenv -unload
            invoke_vsenv -arch x64
            ($env:Path -split ';').count | should -be $first_count
        }
    }

    # ── Architecture Switching ──────────────────────────────────────
    describe 'Architecture Switching' {

        it 'switches from x64 to arm64 with cross-compile syntax' {
            invoke_vsenv -arch x64
            invoke_vsenv -arch arm64
            get_mock_args | should -match 'arm64'
            $env:Path | should -match 'arm64'
        }

        it 'switches from x64 to x86' {
            invoke_vsenv -arch x64
            invoke_vsenv -arch x86
            $env:Path | should -match 'x86'
        }

        it 'preserves user INCLUDE additions across arch switch' {
            invoke_vsenv -arch x64
            $env:INCLUDE += ';C:\Users\custom\include'
            invoke_vsenv -arch arm64
            $env:INCLUDE | should -match 'custom\\include'
        }

        it 'does not accumulate stale entries across rapid switches' {
            invoke_vsenv -arch x64
            invoke_vsenv -arch arm64
            invoke_vsenv -arch x86
            invoke_vsenv -arch x64

            $entries = $env:Path -split ';'
            ($entries | ? { $_ -match 'HostX64\\arm64' }) | should -benullorempty
            ($entries | ? { $_ -match 'HostX64\\x86' })   | should -benullorempty
        }

        it 'treats x64 and amd64 as synonyms' {
            invoke_vsenv -arch x64
            $env:Path | should -match 'HostX64\\x64'

            reset_vsenv
            ri env:* -force -ea ignore
            $script:vsenv_env_snap.getenumerator() | %{
                si -literalpath "env:$($_.key)" $_.value
            }

            invoke_vsenv -arch amd64
            $env:Path | should -match 'HostX64\\x64'
        }
    }

    # ── VCPKG_ROOT Handling ─────────────────────────────────────────
    describe 'VCPKG_ROOT Handling' {

        beforeeach {
            $script:mock_vcpkg_root = join-path $script:temp_dir 'vcpkg'
            ni -itemtype directory $script:mock_vcpkg_root -force | out-null
            $env:VCPKG_ROOT = $script:mock_vcpkg_root
        }

        it 'preserves VCPKG_ROOT value across vsenv load' {
            $before = $env:VCPKG_ROOT
            invoke_vsenv -arch x64
            $env:VCPKG_ROOT | should -be $before
        }

        it 'includes VCPKG_ROOT in PATH after load' {
            invoke_vsenv -arch x64
            $entries = $env:Path -split ';' | %{ $_.trimend('/\') }
            $entries | should -contain $script:mock_vcpkg_root.trimend('/\')
        }

        it 'keeps VCPKG_ROOT in PATH after unload' {
            invoke_vsenv -arch x64
            vsenv -unload
            $entries = $env:Path -split ';' | %{ $_.trimend('/\') }
            $entries | should -contain $script:mock_vcpkg_root.trimend('/\')
        }

        it 'replaces VS-bundled VC\vcpkg with VCPKG_ROOT' {
            invoke_vsenv -arch x64
            $vc_vcpkg = ($env:Path -split ';') | ? { $_ -match '[/\\]VC[/\\]vcpkg$' }
            $vc_vcpkg | should -benullorempty
        }

        context 'VCPKG_ROOT changes between calls' {

            it 'strips old VCPKG_ROOT and adds new one' {
                invoke_vsenv -arch x64
                vsenv -unload

                $new_root = join-path $script:temp_dir 'vcpkg-v143'
                ni -itemtype directory $new_root -force | out-null
                $env:VCPKG_ROOT = $new_root

                invoke_vsenv -arch x64

                $entries = $env:Path -split ';' | %{ $_.trimend('/\') }
                $entries | should -contain $new_root.trimend('/\')
                $entries | should -not -contain $script:mock_vcpkg_root.trimend('/\')
            }

            it 'updates vsenv_vcpkg_in_path tracking variable' {
                invoke_vsenv -arch x64
                get_vsenv_vcpkg_in_path | should -be $script:mock_vcpkg_root.trimend('/\')

                vsenv -unload
                $new_root = join-path $script:temp_dir 'vcpkg-new'
                ni -itemtype directory $new_root -force | out-null
                $env:VCPKG_ROOT = $new_root

                invoke_vsenv -arch x64
                get_vsenv_vcpkg_in_path | should -be $new_root.trimend('/\')
            }

            it 'handles change without intermediate unload' {
                invoke_vsenv -arch x64

                $new_root = join-path $script:temp_dir 'vcpkg-direct'
                ni -itemtype directory $new_root -force | out-null
                $env:VCPKG_ROOT = $new_root

                invoke_vsenv -arch x64

                $entries = $env:Path -split ';' | %{ $_.trimend('/\') }
                $entries | should -contain $new_root.trimend('/\')
                ($entries | ? { $_ -ieq $script:mock_vcpkg_root.trimend('/\') }) |
                    should -benullorempty
            }
        }

        context 'VCPKG_ROOT is unset' {
            it 'does not error when VCPKG_ROOT is null' {
                ri env:VCPKG_ROOT -ea ignore
                { invoke_vsenv -arch x64 } | should -not -throw
            }
        }

        context 'vcpkg LIB/INCLUDE arch rewriting' {
            it 'rewrites vcpkg triplet paths on arch switch' {
                $env:LIB     = "$($script:mock_vcpkg_root)/installed/x64-windows-static/lib"
                $env:INCLUDE = "$($script:mock_vcpkg_root)/installed/x64-windows-static/include"

                invoke_vsenv -arch x64
                invoke_vsenv -arch arm64

                $env:LIB     | should -match 'arm64-windows-static'
                $env:INCLUDE | should -match 'arm64-windows-static'
            }
        }
    }

    # ── PATH Deduplication ──────────────────────────────────────────
    describe 'PATH Deduplication' {

        it 'deduplicates entries differing only by trailing backslash' {
            $d = join-path $script:temp_dir 'dedup-test'
            ni -itemtype directory $d -force | out-null
            $env:Path = "${d}\;${d};$env:Path"

            invoke_vsenv -arch x64

            $found = ($env:Path -split ';') | ? { $_.trimend('/\') -ieq $d.trimend('/\') }
            $found.count | should -be 1
        }

        it 'deduplicates case-insensitively' {
            $d = join-path $script:temp_dir 'CaseTest'
            ni -itemtype directory $d -force | out-null
            $env:Path = "$($d.tolower());$($d.toupper());$env:Path"

            invoke_vsenv -arch x64

            $found = ($env:Path -split ';') | ? { $_.trimend('/\') -ieq $d.trimend('/\') }
            $found.count | should -be 1
        }

        it 'normalizes double backslashes from vcvarsall output' {
            $response = new_vcvarsall_response -arch x64
            $response = $response | %{
                if ($_ -match '^Path=') { $_ -replace 'Common7\\IDE', 'Common7\\\\IDE' }
                else { $_ }
            }
            set_mock_output -lines $response
            vsenv x64

            ($env:Path -split ';') | ? { $_ -match '\\\\' } | should -benullorempty
        }

        it 'keeps first occurrence for duplicates' {
            $first_baseline = ($env:Path -split ';' | ? { $_ })[0]
            invoke_vsenv -arch x64
            ($env:Path -split ';')[0] | should -be $first_baseline
        }
    }

    # ── List Var Management ─────────────────────────────────────────
    describe 'List Var Management' {

        it 'prepends vcvarsall entries BEFORE user entries for INCLUDE/LIB' {
            $env:INCLUDE = 'C:\Users\custom\include'
            invoke_vsenv -arch x64

            $entries = $env:INCLUDE -split ';'
            $custom_idx = [array]::indexof($entries, 'C:\Users\custom\include')
            $msvc_idx = 0
            for ($i = 0; $i -lt $entries.count; $i++) {
                if ($entries[$i] -match 'MSVC') { $msvc_idx = $i; break }
            }
            $msvc_idx | should -belessthan $custom_idx
        }

        it 'records vcvarsall_additions for non-PATH list vars' {
            invoke_vsenv -arch x64
            $state = get_vsenv_state
            $state.vcvarsall_additions | should -not -benullorempty
            $state.vcvarsall_additions['INCLUDE'] | should -not -benullorempty
            $state.vcvarsall_additions['LIB'] | should -not -benullorempty
        }

        it 'subtracts previous vcvarsall additions on arch switch' {
            invoke_vsenv -arch x64
            $env:INCLUDE += ';C:\Users\custom\include'
            invoke_vsenv -arch arm64

            # user addition survives the arch switch
            $env:INCLUDE | should -match 'custom\\include'
            # LIB has arch-specific paths (lib\arm64 vs lib\x64)
            $env:LIB | should -match 'arm64'
        }
    }

    # ── vs_strip_re Pattern ─────────────────────────────────────────
    describe 'vs_strip_re Pattern' {

        beforeall {
            $script:vs_strip_re = '[/\\]Microsoft Visual Studio[/\\]|[/\\]Microsoft SDKs[/\\]|[/\\]Windows Kits[/\\](?:[^/\\]+[/\\](?:bin|lib|include|UnionMetadata|References)[/\\]|NETFXSDK[/\\])|[/\\]Microsoft\.NET[/\\]|[/\\]HTML Help Workshop'
        }

        it 'strips \Microsoft Visual Studio\ paths' {
            'C:\Program Files\Microsoft Visual Studio\2022\Community\VC' |
                should -match $script:vs_strip_re
        }

        it 'strips \Microsoft SDKs\ paths' {
            'C:\Program Files (x86)\Microsoft SDKs\Windows\v10.0A' |
                should -match $script:vs_strip_re
        }

        it 'strips Windows Kits SDK bin paths' {
            'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64' |
                should -match $script:vs_strip_re
        }

        it 'does NOT strip Windows Performance Toolkit' {
            'C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit' |
                should -not -match $script:vs_strip_re
        }

        it 'strips NETFXSDK under Windows Kits' {
            'C:\Program Files (x86)\Windows Kits\NETFXSDK\4.8' |
                should -match $script:vs_strip_re
        }

        it 'strips \Microsoft.NET\ paths' {
            'C:\WINDOWS\Microsoft.NET\Framework64\v4.0.30319' |
                should -match $script:vs_strip_re
        }

        it 'strips HTML Help Workshop' {
            'C:\Program Files (x86)\HTML Help Workshop' |
                should -match $script:vs_strip_re
        }

        it 'does NOT match PowerShell paths' {
            'C:\Program Files\PowerShell\7' | should -not -match $script:vs_strip_re
        }

        it 'does NOT match Git paths' {
            'C:\Program Files\Git\cmd' | should -not -match $script:vs_strip_re
        }

        it 'handles forward slash separators' {
            'C:/Program Files/Microsoft Visual Studio/2022/Community' |
                should -match $script:vs_strip_re
        }
    }

    # ── __VSCMD_PREINIT_* Handling ──────────────────────────────────
    describe '__VSCMD_PREINIT_* Handling' {

        it 'discards __VSCMD_PREINIT_* from vcvarsall output' {
            invoke_vsenv -arch x64
            $env:__VSCMD_PREINIT_PATH | should -benullorempty
        }

        it 'removes pre-existing __VSCMD_PREINIT_* vars' {
            $env:__VSCMD_PREINIT_PATH = 'C:\old\path'
            invoke_vsenv -arch x64
            $env:__VSCMD_PREINIT_PATH | should -benullorempty
        }
    }

    # ── VCPKG_ROOT exclusion from state.vars ────────────────────────
    describe 'VCPKG_ROOT state management' {

        it 'does not store VCPKG_ROOT in state.vars' {
            $env:VCPKG_ROOT = join-path $script:temp_dir 'vcpkg'
            ni -itemtype directory $env:VCPKG_ROOT -force | out-null
            invoke_vsenv -arch x64

            $state = get_vsenv_state
            $state.vars.containskey('VCPKG_ROOT') | should -befalse
        }

        it 'preserves VCPKG_ROOT after vcvarsall might overwrite it' {
            $original = join-path $script:temp_dir 'my-vcpkg'
            ni -itemtype directory $original -force | out-null
            $env:VCPKG_ROOT = $original

            $response = new_vcvarsall_response -arch x64
            $response += 'VCPKG_ROOT=C:\Different\vcpkg'
            set_mock_output -lines $response
            vsenv x64

            $env:VCPKG_ROOT | should -be $original
        }
    }

    # ── Error Handling ──────────────────────────────────────────────
    describe 'Error Handling' {
        it 'throws when vcvarsall exits nonzero' {
            set_mock_output -lines @() -exit_code 1
            { vsenv x64 } | should -throw '*vcvarsall*'
        }
    }

    # ── Verbose Output ──────────────────────────────────────────────
    describe 'Verbose Output' {

        it 'emits the vcvarsall command line via write-verbose' {
            set_mock_output -lines (new_vcvarsall_response -arch x64)
            $verbose = & $script:vbam {
                $VerbosePreference = 'Continue'; vsenv x64
            } 4>&1
            $verbose | ? { $_ -match '^vsenv:' } | should -not -benullorempty
        }

        it 'emits vcvarsall banner lines as verbose' {
            set_mock_output -lines (new_vcvarsall_response -arch x64)
            $verbose = & $script:vbam {
                $VerbosePreference = 'Continue'; vsenv x64
            } 4>&1
            $verbose | ? { $_ -match 'vcvarsall:' } | should -not -benullorempty
        }
    }

    # ── Toolkit Selection ───────────────────────────────────────────
    describe 'Toolkit Selection' {

        beforeall {
            $script:mock_msvc_base = join-path $script:temp_dir 'MockVS\VC\Tools\MSVC'
            ni -itemtype directory $script:mock_msvc_base -force | out-null
            '14.30.30705','14.40.33807','14.42.34433','14.50.35717' | %{
                ni -itemtype directory (join-path $script:mock_msvc_base $_) -force | out-null
            }

            $script:mock_vcvarsall_dir = join-path $script:temp_dir 'MockVS\VC\Auxiliary\Build'
            ni -itemtype directory $script:mock_vcvarsall_dir -force | out-null
            copy-item $script:mock_vcvarsall (join-path $script:mock_vcvarsall_dir 'vcvarsall.bat')

            & $script:vbam {
                $script:vcvarsall = resolve-path $args[0]
            } (join-path $script:mock_vcvarsall_dir 'vcvarsall.bat')
        }

        afterall {
            & $script:vbam {
                $script:vcvarsall = resolve-path $args[0]
            } $script:mock_vcvarsall
        }

        it 'selects latest version in range for v143 (14.3x-14.4x)' {
            $response = new_vcvarsall_response -arch x64 -tools_version '14.42.34433'
            $response += 'VCToolsVersion=14.42.34433'
            set_mock_output -lines $response

            vsenv x64 v143

            get_mock_args | should -match '14\.42\.34433'
        }

        it 'selects 14.50 for v145' {
            $response = new_vcvarsall_response -arch x64 -tools_version '14.50.35717'
            $response += 'VCToolsVersion=14.50.35717'
            set_mock_output -lines $response

            vsenv x64 v145

            get_mock_args | should -match '14\.50\.35717'
        }

        it 'passes exact version string without scanning' {
            $response = new_vcvarsall_response -arch x64 -tools_version '14.30.30705'
            $response += 'VCToolsVersion=14.30.30705'
            set_mock_output -lines $response

            vsenv x64 '14.30.30705'

            get_mock_args | should -match '14\.30\.30705'
        }

        it 'emits warning when toolkit produces no VCToolsVersion' {
            $response = @(
                '[vcvarsall.bat] Environment initialized'
                'Path=%Path%'
                'INCLUDE=C:\dummy\include'
            )
            set_mock_output -lines $response

            # clear VCToolsVersion so the warning triggers
            ri env:VCToolsVersion -ea ignore

            $output = vsenv x64 v143 3>&1
            $warnings = @($output | ?{ $_ -is [System.Management.Automation.WarningRecord] })

            $warnings | should -not -benullorempty
        }
    }

    # ── Build Env Lifecycle ─────────────────────────────────────────
    # setup_build_env calls restore_env, which replaces the environment
    # wholesale while a vsenv_state from the previous build is still set.
    describe 'Build Env Lifecycle' {

        it 'does not accumulate entries across builds' {
            $marker = join-path $script:temp_dir 'pristine-marker'
            $env:Path = $marker + ';' + $env:Path
            save_env

            invoke_vsenv -arch x64
            $first = ($env:Path -split ';').count

            foreach ($build in 1..3) {
                restore_env
                save_env
                invoke_vsenv -arch x64

                ($env:Path -split ';').count | should -be $first
                ($env:Path -split ';') | should -contain $marker
            }
        }

        it 'keeps a restored environment clean of the previous build' {
            $marker = join-path $script:temp_dir 'pristine-marker-2'
            $env:Path = $marker + ';' + $env:Path
            save_env

            invoke_vsenv -arch arm64
            restore_env
            save_env
            invoke_vsenv -arch x64

            $entries = $env:Path -split ';'
            ($entries | ? { $_ -match 'HostX64\\arm64' }) | should -benullorempty
            $entries | should -contain $marker
        }
    }
}

# vim:set sw=4 et:
