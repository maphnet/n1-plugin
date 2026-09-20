#!/usr/bin/env bash
# lib/classify.sh — deterministic path-based diff-surface classifier.
# Pure functions: path string in, category out. No git or filesystem access.

# n1_classify_path <path> → stdout: deps|build|ci|test|docs|config|style|code
n1_classify_path() {
    local p="$1"
    local b; b="${p##*/}"

    # --- deps: dependency manifests and lock files (highest specificity) ---
    case "$b" in
        package.json|package-lock.json|yarn.lock|pnpm-lock.yaml|npm-shrinkwrap.json) echo deps; return ;;
        requirements*.txt|Pipfile|Pipfile.lock|poetry.lock|setup.py|setup.cfg) echo deps; return ;;
        go.mod|go.sum) echo deps; return ;;
        Cargo.toml|Cargo.lock) echo deps; return ;;
        Gemfile|Gemfile.lock) echo deps; return ;;
        pyproject.toml|uv.lock|pdm.lock) echo deps; return ;;
        composer.json|composer.lock) echo deps; return ;;
        build.gradle|build.gradle.kts|settings.gradle|settings.gradle.kts|gradle.lockfile) echo deps; return ;;
        pom.xml|ivy.xml) echo deps; return ;;
        mix.exs|mix.lock) echo deps; return ;;
        Podfile|Podfile.lock|Cartfile|Cartfile.resolved) echo deps; return ;;
        .tool-versions|.node-version|.nvmrc|.python-version|.ruby-version|.go-version) echo deps; return ;;
        flake.nix|flake.lock) echo deps; return ;;
    esac
    case "$b" in
        *.csproj|*.fsproj|*.vbproj) echo deps; return ;;
        *.gemspec) echo deps; return ;;
        packages.config|Directory.Build.props|Directory.Packages.props|global.json) echo deps; return ;;
    esac

    # --- ci: CI/CD configuration ---
    case "$p" in
        .github/workflows/*|.github/actions/*) echo ci; return ;;
        .circleci/*) echo ci; return ;;
        .travis.yml|.travis/*) echo ci; return ;;
        .gitlab-ci.yml|.gitlab/*) echo ci; return ;;
        .buildkite/*|buildkite/*) echo ci; return ;;
        .drone.yml|.drone/*) echo ci; return ;;
        .azure-pipelines.yml|azure-pipelines/*) echo ci; return ;;
        .teamcity/*) echo ci; return ;;
        .github/dependabot.yml) echo ci; return ;;
    esac
    case "$b" in
        Jenkinsfile|Jenkinsfile.*) echo ci; return ;;
        codecov.yml|.codecov.yml) echo ci; return ;;
        renovate.json|.renovaterc|.renovaterc.json) echo ci; return ;;
        appveyor.yml|.appveyor.yml) echo ci; return ;;
    esac

    # --- test: test files, fixtures, test config ---
    case "$p" in
        tests/*|test/*|*/tests/*|*/test/*) echo test; return ;;
        __tests__/*|*/__tests__/*) echo test; return ;;
        spec/*|*/spec/*) echo test; return ;;
        fixtures/*|*/fixtures/*) echo test; return ;;
        testdata/*|*/testdata/*|test-data/*|*/test-data/*) echo test; return ;;
    esac
    case "$b" in
        test_*.*|*_test.*|*.test.*|*.spec.*) echo test; return ;;
        *Test.java|*Tests.java|*Test.kt|*Tests.kt|*Tests.cs) echo test; return ;;
        *_spec.rb|*_spec.lua) echo test; return ;;
        conftest.py|pytest.ini) echo test; return ;;
        jest.config.*|vitest.config.*|karma.conf.*|.nycrc|.nycrc.*) echo test; return ;;
        cypress.config.*|playwright.config.*) echo test; return ;;
    esac

    # --- build: build tooling, bundler config, container definitions ---
    case "$b" in
        Makefile|GNUmakefile) echo build; return ;;
        Dockerfile|Dockerfile.*) echo build; return ;;
        CMakeLists.txt) echo build; return ;;
        Rakefile|Taskfile.yml|Justfile) echo build; return ;;
        Procfile|nixpacks.toml|Aptfile|runtime.txt) echo build; return ;;
        webpack.config.*|rollup.config.*|vite.config.*|esbuild.*) echo build; return ;;
        tsconfig.json|tsconfig.*.json) echo build; return ;;
        babel.config.*|.babelrc|.babelrc.*) echo build; return ;;
        turbo.json|nx.json|lerna.json) echo build; return ;;
        Gruntfile.*|gulpfile.*) echo build; return ;;
    esac
    case "$b" in
        *.mk) echo build; return ;;
        *.dockerfile) echo build; return ;;
        *.cmake) echo build; return ;;
        docker-compose*.yml|docker-compose*.yaml) echo build; return ;;
    esac
    case "$p" in
        scripts/build*|scripts/deploy*|scripts/release*|scripts/package*) echo build; return ;;
    esac

    # --- docs: documentation, readmes, licenses ---
    case "$p" in
        docs/*|*/docs/*|doc/*|*/doc/*) echo docs; return ;;
    esac
    case "$b" in
        README*|CHANGELOG*|LICENSE*|LICENCE*|CONTRIBUTING*|AUTHORS*|NOTICE*|PATENTS*|HISTORY*) echo docs; return ;;
        CODEOWNERS|.mailmap) echo docs; return ;;
    esac
    case "$b" in
        *.md|*.rst|*.adoc) echo docs; return ;;
        *.txt) echo docs; return ;;
    esac

    # --- style: stylesheets and linter/formatter config ---
    case "$b" in
        *.css|*.scss|*.sass|*.less|*.styl) echo style; return ;;
        .eslintrc|.eslintrc.*|.eslintignore) echo style; return ;;
        eslint.config.*) echo style; return ;;
        .prettierrc|.prettierrc.*|.prettierignore) echo style; return ;;
        prettier.config.*) echo style; return ;;
        .stylelintrc|.stylelintrc.*) echo style; return ;;
        stylelint.config.*) echo style; return ;;
        .editorconfig) echo style; return ;;
    esac

    # --- config: generic data/config files (catch-all before code) ---
    case "$b" in
        *.yml|*.yaml) echo config; return ;;
        *.json) echo config; return ;;
        *.toml|*.ini|*.cfg|*.cfg.*|*.conf) echo config; return ;;
        *.xml) echo config; return ;;
        *.env|.env|.env.*) echo config; return ;;
        .gitignore|.gitattributes|.dockerignore|.npmignore|.npmrc|.yarnrc|.yarnrc.*) echo config; return ;;
    esac

    # --- code: everything else ---
    echo code
}

# n1_classify_is_security_hint <path> → exit 0 (true) if path matches security-relevant patterns
n1_classify_is_security_hint() {
    local p="$1"
    local b; b="${p##*/}"
    # directory patterns
    case "$p" in
        auth/*|*/auth/*) return 0 ;;
        crypto/*|*/crypto/*) return 0 ;;
        secrets/*|*/secrets/*) return 0 ;;
        security/*|*/security/*) return 0 ;;
        */middleware/auth*|*/middleware/session*) return 0 ;;
        */permissions/*|*/permission/*) return 0 ;;
        */acl/*|*/rbac/*|*/policy/*) return 0 ;;
        */ssl/*|*/tls/*|*/certs/*|*/certificates/*) return 0 ;;
    esac
    # file extension patterns
    case "$b" in
        *.pem|*.key|*.p12|*.pfx|*.cert|*.crt|*.jks|*.keystore) return 0 ;;
    esac
    # basename keyword patterns
    case "$b" in
        jwt*|oauth*|saml*|oidc*) return 0 ;;
        *password*|*passwd*|*credential*) return 0 ;;
        *auth*) return 0 ;;
        *encrypt*|*decrypt*|*cipher*) return 0 ;;
        *sanitiz*|*validat*) return 0 ;;
    esac
    return 1
}

# n1_classify_files <newline-separated-paths> → stdout: "<path> <category>" per line
n1_classify_files() {
    local paths="$1"
    [ -z "$paths" ] && return 0
    local f
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        printf '%s %s\n' "$f" "$(n1_classify_path "$f")"
    done <<< "$paths"
}

# n1_classify_doc_config_only <newline-separated-paths> → stdout: true|false
# true iff every path classifies as docs or config. Empty input → false (safe default).
n1_classify_doc_config_only() {
    local paths="$1"
    [ -z "$paths" ] && { echo false; return; }
    local f cat found=false
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        found=true
        cat=$(n1_classify_path "$f")
        case "$cat" in
            docs|config) ;;
            *) echo false; return ;;
        esac
    done <<< "$paths"
    [ "$found" = true ] && echo true || echo false
}

# n1_classify_security_hint_any <newline-separated-paths> → stdout: true|false
# true iff any path triggers the security hint.
n1_classify_security_hint_any() {
    local paths="$1"
    [ -z "$paths" ] && { echo false; return; }
    local f
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        n1_classify_is_security_hint "$f" && { echo true; return; }
    done <<< "$paths"
    echo false
}

# n1_classify_all_low_risk <newline-separated-paths> -> stdout: true|false
# true iff every path classifies as deps, style, test, or ci. Empty input -> false (safe default).
n1_classify_all_low_risk() {
    local paths="$1"
    [ -z "$paths" ] && { echo false; return; }
    local f cat found=false
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        found=true
        cat=$(n1_classify_path "$f")
        case "$cat" in
            deps|style|test|ci) ;;
            *) echo false; return ;;
        esac
    done <<< "$paths"
    [ "$found" = true ] && echo true || echo false
}
