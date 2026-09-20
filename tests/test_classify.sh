#!/usr/bin/env bash
# tests/test_classify.sh — unit tests for lib/classify.sh path classifier
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected=[$2] actual=[$3])"; FAIL=$((FAIL+1)); fi; }
source "$REPO_ROOT/lib/classify.sh"

# --- n1_classify_path: deps ---
assert_eq "deps: package.json" "deps" "$(n1_classify_path "package.json")"
assert_eq "deps: package-lock.json" "deps" "$(n1_classify_path "package-lock.json")"
assert_eq "deps: yarn.lock" "deps" "$(n1_classify_path "yarn.lock")"
assert_eq "deps: pnpm-lock.yaml" "deps" "$(n1_classify_path "pnpm-lock.yaml")"
assert_eq "deps: requirements.txt" "deps" "$(n1_classify_path "requirements.txt")"
assert_eq "deps: requirements-dev.txt" "deps" "$(n1_classify_path "requirements-dev.txt")"
assert_eq "deps: Pipfile" "deps" "$(n1_classify_path "Pipfile")"
assert_eq "deps: Pipfile.lock" "deps" "$(n1_classify_path "Pipfile.lock")"
assert_eq "deps: poetry.lock" "deps" "$(n1_classify_path "poetry.lock")"
assert_eq "deps: go.mod" "deps" "$(n1_classify_path "go.mod")"
assert_eq "deps: go.sum" "deps" "$(n1_classify_path "go.sum")"
assert_eq "deps: Cargo.toml" "deps" "$(n1_classify_path "Cargo.toml")"
assert_eq "deps: Cargo.lock" "deps" "$(n1_classify_path "Cargo.lock")"
assert_eq "deps: Gemfile" "deps" "$(n1_classify_path "Gemfile")"
assert_eq "deps: Gemfile.lock" "deps" "$(n1_classify_path "Gemfile.lock")"
assert_eq "deps: pyproject.toml" "deps" "$(n1_classify_path "pyproject.toml")"
assert_eq "deps: uv.lock" "deps" "$(n1_classify_path "uv.lock")"
assert_eq "deps: setup.py" "deps" "$(n1_classify_path "setup.py")"
assert_eq "deps: setup.cfg" "deps" "$(n1_classify_path "setup.cfg")"
assert_eq "deps: pom.xml" "deps" "$(n1_classify_path "pom.xml")"
assert_eq "deps: build.gradle" "deps" "$(n1_classify_path "build.gradle")"
assert_eq "deps: composer.json" "deps" "$(n1_classify_path "composer.json")"
assert_eq "deps: mix.exs" "deps" "$(n1_classify_path "mix.exs")"
assert_eq "deps: .nvmrc" "deps" "$(n1_classify_path ".nvmrc")"
assert_eq "deps: .tool-versions" "deps" "$(n1_classify_path ".tool-versions")"
assert_eq "deps: flake.lock" "deps" "$(n1_classify_path "flake.lock")"
assert_eq "deps: nested csproj" "deps" "$(n1_classify_path "src/MyApp/MyApp.csproj")"

# --- n1_classify_path: ci ---
assert_eq "ci: github workflow" "ci" "$(n1_classify_path ".github/workflows/ci.yml")"
assert_eq "ci: github action" "ci" "$(n1_classify_path ".github/actions/build/action.yml")"
assert_eq "ci: gitlab-ci" "ci" "$(n1_classify_path ".gitlab-ci.yml")"
assert_eq "ci: circleci config" "ci" "$(n1_classify_path ".circleci/config.yml")"
assert_eq "ci: travis" "ci" "$(n1_classify_path ".travis.yml")"
assert_eq "ci: Jenkinsfile" "ci" "$(n1_classify_path "Jenkinsfile")"
assert_eq "ci: buildkite" "ci" "$(n1_classify_path ".buildkite/pipeline.yml")"
assert_eq "ci: codecov" "ci" "$(n1_classify_path "codecov.yml")"
assert_eq "ci: renovate" "ci" "$(n1_classify_path "renovate.json")"
assert_eq "ci: dependabot" "ci" "$(n1_classify_path ".github/dependabot.yml")"

# --- n1_classify_path: test ---
assert_eq "test: tests/ dir" "test" "$(n1_classify_path "tests/test_foo.py")"
assert_eq "test: nested tests/" "test" "$(n1_classify_path "src/tests/test_bar.py")"
assert_eq "test: __tests__ dir" "test" "$(n1_classify_path "src/__tests__/foo.test.js")"
assert_eq "test: spec dir" "test" "$(n1_classify_path "spec/models/user_spec.rb")"
assert_eq "test: .spec.ts" "test" "$(n1_classify_path "src/calc.spec.ts")"
assert_eq "test: .test.js" "test" "$(n1_classify_path "src/utils.test.js")"
assert_eq "test: _test.go" "test" "$(n1_classify_path "pkg/calc_test.go")"
assert_eq "test: test_ prefix" "test" "$(n1_classify_path "test_main.py")"
assert_eq "test: Test.java" "test" "$(n1_classify_path "src/CalcTest.java")"
assert_eq "test: conftest.py" "test" "$(n1_classify_path "conftest.py")"
assert_eq "test: jest.config.js" "test" "$(n1_classify_path "jest.config.js")"
assert_eq "test: fixtures dir" "test" "$(n1_classify_path "fixtures/sample.json")"
assert_eq "test: testdata dir" "test" "$(n1_classify_path "testdata/input.txt")"

# --- n1_classify_path: build ---
assert_eq "build: Makefile" "build" "$(n1_classify_path "Makefile")"
assert_eq "build: file.mk" "build" "$(n1_classify_path "rules.mk")"
assert_eq "build: Dockerfile" "build" "$(n1_classify_path "Dockerfile")"
assert_eq "build: Dockerfile.prod" "build" "$(n1_classify_path "Dockerfile.prod")"
assert_eq "build: docker-compose.yml" "build" "$(n1_classify_path "docker-compose.yml")"
assert_eq "build: docker-compose.prod.yaml" "build" "$(n1_classify_path "docker-compose.prod.yaml")"
assert_eq "build: CMakeLists.txt" "build" "$(n1_classify_path "CMakeLists.txt")"
assert_eq "build: webpack.config.js" "build" "$(n1_classify_path "webpack.config.js")"
assert_eq "build: vite.config.ts" "build" "$(n1_classify_path "vite.config.ts")"
assert_eq "build: rollup.config.mjs" "build" "$(n1_classify_path "rollup.config.mjs")"
assert_eq "build: tsconfig.json" "build" "$(n1_classify_path "tsconfig.json")"
assert_eq "build: tsconfig.app.json" "build" "$(n1_classify_path "tsconfig.app.json")"
assert_eq "build: babel.config.js" "build" "$(n1_classify_path "babel.config.js")"
assert_eq "build: turbo.json" "build" "$(n1_classify_path "turbo.json")"
assert_eq "build: Procfile" "build" "$(n1_classify_path "Procfile")"
assert_eq "build: Justfile" "build" "$(n1_classify_path "Justfile")"
assert_eq "build: scripts/build.sh" "build" "$(n1_classify_path "scripts/build.sh")"
assert_eq "build: scripts/deploy.sh" "build" "$(n1_classify_path "scripts/deploy.sh")"

# --- n1_classify_path: docs ---
assert_eq "docs: README.md" "docs" "$(n1_classify_path "README.md")"
assert_eq "docs: CHANGELOG" "docs" "$(n1_classify_path "CHANGELOG")"
assert_eq "docs: CHANGELOG.md" "docs" "$(n1_classify_path "CHANGELOG.md")"
assert_eq "docs: LICENSE" "docs" "$(n1_classify_path "LICENSE")"
assert_eq "docs: docs/ dir" "docs" "$(n1_classify_path "docs/guide.md")"
assert_eq "docs: nested docs/" "docs" "$(n1_classify_path "api/docs/reference.md")"
assert_eq "docs: .rst" "docs" "$(n1_classify_path "api.rst")"
assert_eq "docs: .adoc" "docs" "$(n1_classify_path "guide.adoc")"
assert_eq "docs: CONTRIBUTING" "docs" "$(n1_classify_path "CONTRIBUTING.md")"
assert_eq "docs: CODEOWNERS" "docs" "$(n1_classify_path "CODEOWNERS")"
assert_eq "docs: plain .txt" "docs" "$(n1_classify_path "notes.txt")"

# --- n1_classify_path: style ---
assert_eq "style: .css" "style" "$(n1_classify_path "src/app.css")"
assert_eq "style: .scss" "style" "$(n1_classify_path "src/theme.scss")"
assert_eq "style: .sass" "style" "$(n1_classify_path "src/base.sass")"
assert_eq "style: .less" "style" "$(n1_classify_path "src/vars.less")"
assert_eq "style: eslintrc.json" "style" "$(n1_classify_path ".eslintrc.json")"
assert_eq "style: eslint.config.js" "style" "$(n1_classify_path "eslint.config.js")"
assert_eq "style: prettierrc" "style" "$(n1_classify_path ".prettierrc")"
assert_eq "style: .editorconfig" "style" "$(n1_classify_path ".editorconfig")"
assert_eq "style: stylelintrc" "style" "$(n1_classify_path ".stylelintrc.json")"

# --- n1_classify_path: config ---
assert_eq "config: .yml" "config" "$(n1_classify_path "app.yml")"
assert_eq "config: .yaml" "config" "$(n1_classify_path "config.yaml")"
assert_eq "config: .json" "config" "$(n1_classify_path "settings.json")"
assert_eq "config: .toml" "config" "$(n1_classify_path "config.toml")"
assert_eq "config: .ini" "config" "$(n1_classify_path "app.ini")"
assert_eq "config: .cfg" "config" "$(n1_classify_path "setup.cfg.bak")"
assert_eq "config: .env" "config" "$(n1_classify_path ".env")"
assert_eq "config: .env.local" "config" "$(n1_classify_path ".env.local")"
assert_eq "config: .gitignore" "config" "$(n1_classify_path ".gitignore")"
assert_eq "config: .gitattributes" "config" "$(n1_classify_path ".gitattributes")"
assert_eq "config: .dockerignore" "config" "$(n1_classify_path ".dockerignore")"
assert_eq "config: .npmrc" "config" "$(n1_classify_path ".npmrc")"
assert_eq "config: .xml" "config" "$(n1_classify_path "log4j.xml")"

# --- n1_classify_path: code (default) ---
assert_eq "code: .py" "code" "$(n1_classify_path "src/main.py")"
assert_eq "code: .ts" "code" "$(n1_classify_path "src/app.ts")"
assert_eq "code: .tsx" "code" "$(n1_classify_path "src/App.tsx")"
assert_eq "code: .js" "code" "$(n1_classify_path "src/index.js")"
assert_eq "code: .go" "code" "$(n1_classify_path "cmd/server.go")"
assert_eq "code: .rs" "code" "$(n1_classify_path "src/lib.rs")"
assert_eq "code: .java" "code" "$(n1_classify_path "src/Main.java")"
assert_eq "code: .cs" "code" "$(n1_classify_path "src/Program.cs")"
assert_eq "code: .rb" "code" "$(n1_classify_path "app/models/user.rb")"
assert_eq "code: .sh" "code" "$(n1_classify_path "lib/helper.sh")"
assert_eq "code: .c" "code" "$(n1_classify_path "src/main.c")"
assert_eq "code: .cpp" "code" "$(n1_classify_path "src/engine.cpp")"
assert_eq "code: .swift" "code" "$(n1_classify_path "Sources/App.swift")"
assert_eq "code: .kt" "code" "$(n1_classify_path "src/Main.kt")"
assert_eq "code: no extension" "code" "$(n1_classify_path "src/binary")"

# --- specificity: deps wins over config ---
assert_eq "spec: package.json->deps not config" "deps" "$(n1_classify_path "package.json")"
assert_eq "spec: pyproject.toml->deps not config" "deps" "$(n1_classify_path "pyproject.toml")"
assert_eq "spec: pom.xml->deps not config" "deps" "$(n1_classify_path "pom.xml")"
assert_eq "spec: composer.json->deps not config" "deps" "$(n1_classify_path "composer.json")"

# --- specificity: build wins over config ---
assert_eq "spec: docker-compose.yml->build" "build" "$(n1_classify_path "docker-compose.yml")"
assert_eq "spec: tsconfig.json->build" "build" "$(n1_classify_path "tsconfig.json")"
assert_eq "spec: turbo.json->build" "build" "$(n1_classify_path "turbo.json")"

# --- specificity: ci wins over config ---
assert_eq "spec: github workflow->ci" "ci" "$(n1_classify_path ".github/workflows/ci.yml")"
assert_eq "spec: codecov.yml->ci" "ci" "$(n1_classify_path "codecov.yml")"
assert_eq "spec: renovate.json->ci" "ci" "$(n1_classify_path "renovate.json")"

# --- specificity: test config wins over config ---
assert_eq "spec: jest.config.js->test" "test" "$(n1_classify_path "jest.config.js")"
assert_eq "spec: conftest.py->test" "test" "$(n1_classify_path "conftest.py")"

# --- n1_classify_is_security_hint ---
n1_classify_is_security_hint "auth/login.py" && R=0 || R=1; assert_eq "sec: auth/ dir" "0" "$R"
n1_classify_is_security_hint "src/auth/middleware.js" && R=0 || R=1; assert_eq "sec: nested auth/" "0" "$R"
n1_classify_is_security_hint "src/crypto/hash.go" && R=0 || R=1; assert_eq "sec: crypto/ dir" "0" "$R"
n1_classify_is_security_hint "config/secrets/api.yml" && R=0 || R=1; assert_eq "sec: secrets/ dir" "0" "$R"
n1_classify_is_security_hint "security/policy.rego" && R=0 || R=1; assert_eq "sec: security/ dir" "0" "$R"
n1_classify_is_security_hint "certs/server.pem" && R=0 || R=1; assert_eq "sec: .pem file" "0" "$R"
n1_classify_is_security_hint "keys/deploy.key" && R=0 || R=1; assert_eq "sec: .key file" "0" "$R"
n1_classify_is_security_hint "src/jwt_handler.py" && R=0 || R=1; assert_eq "sec: jwt basename" "0" "$R"
n1_classify_is_security_hint "src/oauth_client.ts" && R=0 || R=1; assert_eq "sec: oauth basename" "0" "$R"
n1_classify_is_security_hint "lib/password_utils.py" && R=0 || R=1; assert_eq "sec: password basename" "0" "$R"
n1_classify_is_security_hint "src/middleware/auth_check.js" && R=0 || R=1; assert_eq "sec: middleware auth" "0" "$R"
n1_classify_is_security_hint "src/permissions/rbac.go" && R=0 || R=1; assert_eq "sec: permissions dir" "0" "$R"
n1_classify_is_security_hint "src/utils/format.py" && R=0 || R=1; assert_eq "sec: non-security file" "1" "$R"
n1_classify_is_security_hint "README.md" && R=0 || R=1; assert_eq "sec: readme" "1" "$R"
n1_classify_is_security_hint "src/app.css" && R=0 || R=1; assert_eq "sec: css file" "1" "$R"
n1_classify_is_security_hint "package.json" && R=0 || R=1; assert_eq "sec: package.json" "1" "$R"

# --- n1_classify_doc_config_only ---
assert_eq "dco: all docs" "true" "$(n1_classify_doc_config_only "README.md
CHANGELOG.md")"
assert_eq "dco: docs+config" "true" "$(n1_classify_doc_config_only "README.md
.gitignore
settings.json")"
assert_eq "dco: includes code file" "false" "$(n1_classify_doc_config_only "README.md
src/main.py")"
assert_eq "dco: includes deps" "false" "$(n1_classify_doc_config_only "package.json
README.md")"
assert_eq "dco: includes test" "false" "$(n1_classify_doc_config_only "tests/test_foo.py")"
assert_eq "dco: single doc" "true" "$(n1_classify_doc_config_only "LICENSE")"
assert_eq "dco: single config" "true" "$(n1_classify_doc_config_only ".env")"
assert_eq "dco: empty input" "false" "$(n1_classify_doc_config_only "")"

# --- n1_classify_security_hint_any ---
assert_eq "sha: has security path" "true" "$(n1_classify_security_hint_any "README.md
auth/login.py")"
assert_eq "sha: all non-security" "false" "$(n1_classify_security_hint_any "README.md
src/main.py")"
assert_eq "sha: empty input" "false" "$(n1_classify_security_hint_any "")"
assert_eq "sha: single security" "true" "$(n1_classify_security_hint_any "src/crypto/aes.go")"

# --- n1_classify_files output format ---
OUT=$(n1_classify_files "src/main.py
README.md
package.json")
assert_eq "files: line count" "3" "$(echo "$OUT" | wc -l | tr -d ' ')"
assert_eq "files: code line" "src/main.py code" "$(echo "$OUT" | head -1)"
assert_eq "files: docs line" "README.md docs" "$(echo "$OUT" | sed -n 2p)"
assert_eq "files: deps line" "package.json deps" "$(echo "$OUT" | tail -1)"

# --- n1_classify_all_low_risk ---
assert_eq "alr: all deps" "true" "$(n1_classify_all_low_risk "package.json
yarn.lock")"
assert_eq "alr: all test" "true" "$(n1_classify_all_low_risk "tests/test_foo.py
conftest.py")"
assert_eq "alr: all ci" "true" "$(n1_classify_all_low_risk ".github/workflows/ci.yml")"
assert_eq "alr: all style" "true" "$(n1_classify_all_low_risk ".eslintrc.json
src/app.css")"
assert_eq "alr: mixed low-risk" "true" "$(n1_classify_all_low_risk "package.json
.github/workflows/ci.yml
tests/test_bar.py
.prettierrc")"
assert_eq "alr: includes code" "false" "$(n1_classify_all_low_risk "package.json
src/main.py")"
assert_eq "alr: includes docs" "false" "$(n1_classify_all_low_risk "README.md
package.json")"
assert_eq "alr: includes config" "false" "$(n1_classify_all_low_risk ".gitignore
package.json")"
assert_eq "alr: includes build" "false" "$(n1_classify_all_low_risk "Dockerfile
package.json")"
assert_eq "alr: empty input" "false" "$(n1_classify_all_low_risk "")"
assert_eq "alr: single code file" "false" "$(n1_classify_all_low_risk "src/app.ts")"

echo; echo "Passed: $PASS  Failed: $FAIL"; [ "$FAIL" -eq 0 ]
