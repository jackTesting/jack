branch := `git symbolic-ref HEAD`
config := "quiet"
run := "bazel run --config=" + config
bin_dir := env_var_or_default("HOME", ".") + "/bin"
fetch_bin := "false"
krm_fns_dir := "cmd/kpt-fns"
ci := env_var_or_default("CI", "false")

# variables exported to recipes as environment vars
export EDGE_BINARIES_TARGET := "//hack/build:all_binaries"
export BINARY_RELEASE_BUCKET := "edge-bin"
export EDGE_BIN_DIR := bin_dir
export INTEGRATION_TEST_TAG := "integration"

# will show our recipes if you simply run `just`
default:
  @just --list --list-prefix ' -- '

################################################################################
# TOOL WRAPPERS
################################################################################

# run ibazel with a preferred set of flags
ibazel +ARGS:
  ibazel -run_output_interactive=false {{ARGS}}

alias ib := ibazel

################################################################################
# WORKFLOW
#
# These recipes are highlighted because they will typically be the most relied 
# on when working locally.  Recipes defined here might be slightly different
# than the verify /  update variants ran in CI to optimize for performance.
#
# You should still run just verify (or just verify-all if you are being thorough)
# before submitting a PR.
#
################################################################################

# execute the same CI process that is ran by on presubmit
ci +ARGS: clean-tests
  {{run}} hack/build/ci/leaf -- {{ARGS}}

# push one or more containers, e.g. just pusha cmd/jack.
pusha package +ARGS="":
  {{run}} hack/tools/pusha -- -package {{package}} {{ARGS}}

alias push := pusha

# link built binaries to {{bin_dir}} so that most recent local build is always on $PATH
link:
  just bin_dir={{bin_dir}} hack/link-tools

# update based on remote and prune merged + deleted branches
fetch:
  git fetch origin --prune

# bazel build wrapper
build target="//...":
  bazel build {{target}} --config={{config}}

# bazel test wrapper
test target="//...":
  #!/usr/bin/env bash
  if [[ {{config}} == "quiet" ]]; then 
    bazel test {{target}}; 
  else bazel test --config={{config}}; 
  fi

# run integration tests 
integration target="//..." +ARGS="":
  #!/usr/bin/env bash
  args=$(echo "{{ARGS}}" | sed 's/[^ ]* */--test_arg=&/g')
  bazel test $(just list-integration-tests {{target}}) \
    --config=integration \
    --test_arg=-repo-root=$(pwd) \
    $args

alias i := integration

# query for integration test targets
list-integration-tests under="//...":
  bazel query "kind(.*_test, attr('tags', '{{INTEGRATION_TEST_TAG}}', {{under}}))"

# tags a test target as an integration test, making it available to integration test scripting
register-integration-test target:
  # tags = [ "integration" ] makes test visible to integration test scripting
  buildozer 'add tags {{INTEGRATION_TEST_TAG}}' {{target}} || true
  # makes test/config.json available to an integration test target
  buildozer 'add data //test:config_json' {{target}} || true

# bazel run wrapper
run target +ARGS="":
  {{run}} {{target}} -- {{ARGS}}

# remove junit test reports produced by Baazel
clean-tests:
  find -L "$(bazel info bazel-testlogs)" -name 'test.xml' | xargs rm -f {}

# automatically format BUILD, YAML, and Go files
format: update-format fmt-manifests
  
# runs configured fast go linters in fix mode by default, provided arguments will be used instead
golint +ARGS="--fast --fix":
  {{run}} //:golangcilint -- {{ARGS}}

# format manifests under config/
fmt-manifests dir="":
  #!/usr/bin/env bash
  if [ -z {{dir}} ]; then
    {{run}} hack/tools/fmt-manifests 
  else
    {{run}} hack/tools/fmt-manifests -- --directory {{dir}}
  fi

# generates BUILD files for Golang code
gazelle:
  just update-gazelle

chariot port:
  kubectl port-forward -n chariot deployment/chariot {{port}}:8080

alias g := gazelle

generate-mocks:
    go install github.com/golang/mock/mockgen@v1.6.0
    mockgen -destination=pkg/backend/mocks/mock_gke_service.go -package=mocks edge-infra.dev/pkg/backend/services GkeService
    mockgen -destination=pkg/backend/mocks/mock_secret_service.go -package=mocks edge-infra.dev/pkg/backend/services SecretService
    mockgen -destination=pkg/backend/mocks/mock_gcp_client_service.go -package=mocks edge-infra.dev/pkg/backend/services GcpClientService
    mockgen -destination=pkg/backend/mocks/mock_secret_manager_service.go -package=mocks edge-infra.dev/pkg/backend/types SecretManagerService
    mockgen -destination=pkg/backend/mocks/mock_gcp_compute_service.go -package=mocks edge-infra.dev/pkg/backend/types ComputeService
    mockgen -destination=pkg/backend/mocks/mock_gcp_container_service.go -package=mocks edge-infra.dev/pkg/backend/types ContainerService
    mockgen -destination=pkg/backend/mocks/mock_query_service.go -package=mocks edge-infra.dev/pkg/backend/types QueryService
    mockgen -destination=pkg/backend/mocks/mock_big_query_service.go -package=mocks edge-infra.dev/pkg/backend/types BigQueryService
    mockgen -destination=pkg/backend/mocks/mock_pub_sub_service.go -package=mocks edge-infra.dev/pkg/backend/types PubSubService
    mockgen -destination=pkg/backend/mocks/mock_launch_darkly_service.go -package=mocks edge-infra.dev/pkg/backend/services/launchdarkly LDService
    # re-generate BUILD files based on updated mocks
    just gazelle
    
alias update-mocks := generate-mocks

generate-gql:
    {{run}} pkg/backend:gqlgen

alias update-gql := generate-gql

vset +ARGS="":
  just g
  just run cmd/vset -p {{ARGS}}
################################################################################
# SCAFFOLDING NEW DELIVERABLES
#
# These recipes help automate set up of new deliverables, such as wiring up 
# container push build rules.
################################################################################

# create a new kpt function package
new-kpt-fn pkg struct +ARGS="":
  {{run}} //tools/kpt/new-fn -- --package-name {{pkg}} --struct-name {{struct}} {{ARGS}}
  just gazelle
  just add-bin-to-release //cmd/kpt-fns/{{pkg}} kpt-{{pkg}}
  # add it to binaries included in our build image
  # TODO: remove this once 1617 is closed and we no longer rely on baked in KRM
  #       function binaries
  buildozer 'dict_add files //cmd/kpt-fns/{{pkg}}:kpt-{{pkg}}' hack/build/build-image:repo_tools
  # add kpt fn to filegroup depended on by scripts that execute our KRM function
  # pipeline
  buildozer 'add data //cmd/kpt-fns/{{pkg}}' //:krm_fns
  # format updated BUILD file
  just update-buildifier

# add container build + publish targets for a Golang package
setup-go-container-publish package cgo="false":
  #!/usr/bin/env bash
  # add import for go_image and container_push macros
  buildozer 'new_load //tools/bzl:containers.bzl go_image container_push' {{package}}:__pkg__
  # create container target
  buildozer 'new go_image container' {{package}}:__pkg__ 
  buildozer "add embed :$(basename {{package}})_lib" {{package}}:container
  buildozer 'set tags manual no-remote-cache' {{package}}:container
  # create container_push target
  buildozer 'new container_push container_push' {{package}}:__pkg__
  buildozer "set image_name \"$(basename {{package}})"\" {{package}}:container_push
  # enable cgo 
  if [[ "{{cgo}}" == "true" ]]; then 
    buildozer 'set cgo True' {{package}}:container; 
  fi
  # cleanup imports
  buildozer 'fix unusedLoads' {{package}}:__pkg__ || true

# add binary build target to artifacts published during release
add-bin-to-release target name:
  buildozer 'dict_add files {{target}}:{{name}}' ${EDGE_BINARIES_TARGET}

# add required envtest binary deps (kube-apiserver, etcd) to a packages tests
enable-envtest pkg:
  buildozer \
    'add data //tools/deps:etcd //tools/deps:kube-apiserver //tools/deps:kubectl' \
    {{pkg}}:"$(basename {{pkg}})_test"

################################################################################
# VERIFY
#
# Verify that static asset generation / automated changes are up-to-date.
################################################################################

# run full verification in CI, otherwise run fast verificaton
verify:
  just {{ if ci == "true" { "verify-all" } else { "verify-fast" } }}

# full set of verification scripts ran in CI
verify-all: verify-container-targets verify-buildifier verify-golangcilint verify-gazelle verify-go-repos verify-controller-gen-targets verify-manifests verify-gopherage verify-gql verify-mocks verify-preprod-manifests verify-dev-manifests verify-krm-fn-filegroup

# quick verifications, intended to be used locally, should run in < 10 seconds ideally
verify-fast: verify-buildifier (golint "--fast") verify-gazelle

# Exits script if working directory is dirty. If it's run interactively in the terminal
# the user can commit changes in a second terminal. This script will wait.
ensure-clean-wd:
  #!/usr/bin/env bash
  set -euxo pipefail
  while ! git diff HEAD --exit-code &>/dev/null; do
    echo -e "\nUnexpected dirty working directory:\n"
    if tty -s; then
        git status -s
    else
        git diff -a # be more verbose in log files without tty
        exit 1
    fi | sed 's/^/  /'
    echo -e "\nCommit your changes in another terminal and then continue here by pressing enter."
    read -r
  done 1>&2

# ensures containers targets have expected Bazel tags
verify-container-targets: ensure-clean-wd
  ./hack/verify/container-targets.sh

# verifies that we have a k8s-codegen target for all of our Go code defining k8s types
verify-controller-gen-targets:
  ./hack/verify/controller-gen-targets.sh

# verifies that go dependencies are up-to-date
verify-go-repos: ensure-clean-wd
  ./hack/verify/go-repo-targets.sh

# runs golangci-lint with config used for presubmit checks
verify-golangcilint:
  {{run}} //:golangcilint

# verifies generated BUILD files are up-to-date
verify-gazelle:
  {{run}} //:verify-gazelle

# verifies BUILD files are formatted correctly
verify-buildifier:
  #!/usr/bin/env bash
  set -eu
  # this is a terrible hack to get around node_modules/ existing and containing
  # buildifier errors.
  # see https://github.com/bazelbuild/buildtools/issues/801 for workarounds
  rm -rf node_modules
  {{run}} //:verify-buildifier

# verifies that checked in manifests are up-to-date and pass Kpt validation funcs
verify-manifests: ensure-clean-wd
  #!/usr/bin/env bash
  set -eu
  just update-manifests
  if [ -z "$(git status --porcelain)" ]; then
    echo 'manifest generation + format are up-to-date'
  else
    echo 'manifest generation + format are not up-to-date, run just update-manifests'
    echo 'the following files aren not up-to-date:'
    git status
    exit 1
  fi

# verifies that gopherage static assets are up-to-date
verify-gopherage: ensure-clean-wd 
  #!/usr/bin/env bash
  set -eu
  just update-gopherage
    if [ -z "$(git status --porcelain)" ]; then
    echo 'gopherage static assets in sync'
  else
    echo 'gopherage static assets have fallen out of sync!'
    echo 'run just hack/update/gopherage and commit the results'
    exit 1
  fi

# verifies graphql generation output is up-to-date
verify-gql:
  #!/usr/bin/env bash
  set -eu
  just update-gql
  if [ -z "$(git status --porcelain)" ]; then
    echo 'graphql code generation is up-to-date'
  else
    echo 'graphql code generation is not up-to-date, run just update-gql'
    echo 'the following files aren not up-to-date:'
    git status
    exit 1
  fi

# verifies mockgen generation output is up-to-date
verify-mocks:
  #!/usr/bin/env bash
  set -eu
  just update-mocks
  if [ -z "$(git status --porcelain)" ]; then
    echo 'generated go mocks are up-to-date'
  else
    echo 'generated go mocks are not up-to-date, run just update-mocks'
    echo 'the following files aren not up-to-date:'
    git status
    exit 1
  fi

verify-preprod-manifests:
  #!/usr/bin/env bash
  set -euxo pipefail
  echo "verifying platform-infra manifests"
  {{run}} kustomize build -- --load-restrictor=LoadRestrictionsNone config/platform-infra/preprod/manifests > /dev/null

verify-dev-manifests:
  #!/usr/bin/env bash
  set -euxo pipefail
  echo "verifying dev-infra manifests"
  {{run}} kustomize build -- --load-restrictor=LoadRestrictionsNone config/dev-infra/manifests > /dev/null

# ensures generated filegroup containing KRM function binaries is up-to-date
verify-krm-fn-filegroup: ensure-clean-wd
  #!/usr/bin/env bash
  set -eu
  just update-krm-fn-filegroup
  if [ -z "$(git status --porcelain)" ]; then
    echo 'the filegroup krm_fns in BUILD.bazel is up-to-date'
  else
    echo 'the filegroup krm_fns in BUILD.bazel is not up-to-date, run just update-krm-fn-filegroup'
    echo 'the following files aren not up-to-date:'
    git status
    exit 1
  fi

################################################################################
# UPDATE
#
# Update various static assets in the repository.
# 
# Typically these recipes are accompanied by a verify recipe that ensures each
# udpate recipe has the correct output for the currently checked out tree.  This
# is used during presubmit to ensure things don't happen such as:
#
# - updating Go code for K8s type and not re-generating related manifests/code
# - updating manifests/code/etc and not formatting them
################################################################################

acmdir := "config/anthos"

# runs all recipes that update repo state
update: check-clean update-container-targets update-gopherage update-gen update-format commit

# file generation targets
update-gen: update-k8s-codegen update-go-repos update-manifests generate-gql generate-mocks

# file formatting targets
update-format: update-buildifier golint

# updates manifests (generation, import, transform, cleanup)
update-manifests: update-manifest-gen update-acm-imports run-krm-fns

# for committing changes once finished
check-clean:
  #!/usr/bin/env bash
  if [ -z "$(git status --porcelain)" ]; then
    echo "clean!" > .gitclean
  else
    echo "working directory not clean, not committing changes"
  fi

commit:
  #!/usr/bin/env bash
  if [ -f .gitclean ]; then
    echo "checking whether to commit changes..."
    rm .gitclean
    if [ -z "$(git status --porcelain)" ]; then
      echo "clean, nothing to commit"
    else
      echo "committing!"
      git add --all
      git commit -m 'AUTOMATED: just update-all'
    fi
  else
    echo "not committing!"
  fi

update-acm-imports:
  ./hack/update/import-all.sh
  # TODO: remove this one we have broken free of the config/anthos/manifests dir
  {{run}} kustomize build config/components/info/rbac > {{acmdir}}/manifests/namespaces/kube-public/edge-info-rbac.yaml
  {{run}} kustomize build config/components/pinitctl > {{acmdir}}/manifests/namespaces/edge/pinitctl/manifests.yaml
  {{run}} kustomize build config/components/linkerdctl/base > {{acmdir}}/manifests/namespaces/edge/store/linkerdctl/manifests.yaml
  {{run}} kustomize build config/anthos-imports/k8s-cfg-connector > {{acmdir}}/manifests/namespaces/k8s-cfg-connector/configconnector-operator-system/manifests.yaml
  {{run}} kustomize build config/anthos-imports/cert-manager > {{acmdir}}/manifests/namespaces/cert-manager/manifests.yaml
  {{run}} kustomize build config/components/couchctl > {{acmdir}}/manifests/namespaces/edge/couchctl/manifests.yaml
  {{run}} kustomize build -- --load-restrictor=LoadRestrictionsNone config/anthos-imports/flux-system > {{acmdir}}/manifests/namespaces/flux-system/manifests.yaml
  {{run}} kustomize build config/components/dennis > {{acmdir}}/manifests/namespaces/edge/dennis/manifests.yaml

# generates BUILD files for Go
update-gazelle:
  {{run}} //:gazelle

# updates container-targets with manual and no-remote-cache tags
update-container-targets:
  ./hack/update/container-targets.sh

# formats BUILD/Bazel files
update-buildifier:
  {{run}} //:buildifier

# triggers all controller-gen targets for generating code
update-k8s-codegen expr="//...":
  #!/usr/bin/env bash
  GENTARGETS=($(bazel query "kind(sh_binary, attr('generator_function', 'gen_code', {{expr}}))"))
  for target in "${GENTARGETS[@]}"
  do
    {{run}} "$target"
  done

# triggers all controller-gen targets for generating manifests
update-manifest-gen expr="//...":
  #!/usr/bin/env bash
  GENTARGETS=($(bazel query "kind(sh_binary, attr('generator_function', 'gen_rbac|gen_crds', {{expr}}))"))
  for target in "${GENTARGETS[@]}"
  do
    {{run}} "$target"
  done
  {{ if ci == "false" { "just fmt-manifests" } else { "" } }}

# run this if you have introduced a new Go dependency into the repository -- updates go.mod and generates go_repository targets used by Bazel to manage Go deps
update-go-repos:
  #!/usr/bin/env bash
  set -euxo pipefail
  # make go update our go.mod based on current go code in this repo
  {{run}} @go_sdk//:bin/go mod tidy -- -go=1.17 -v
  # translate our go.mod into a list of go_repository() so Bazel understands it
  {{run}} //:gazelle -- update-repos \
    -from_file=go.mod \
    -to_macro=tools/deps/go.bzl%go_repositories \
    -prune=true \
    -build_file_proto_mode=disable_global
  # re-generate our BUILD file for Golang code since updating dependencies
  # could impact it
  {{run}} //:gazelle

# runs KRM function pipelines for platform infra K8s manifests
update-platform-infra resultsdir="tmp/kpt-pipeline-results":
  echo "updating platform-infra manifests"
  {{run}} config/platform-infra/preprod:run_krm_fns -- {{resultsdir}}
  {{ if ci == "false" { "just fmt-manifests" } else { "" } }}

# runs all KRM function pipelines
run-krm-fns resultsdir="tmp/kpt-pipeline-results" expr="//config/...":
  #!/usr/bin/env bash
  set -euxo pipefail
  mkdir -p {{resultsdir}}
  KRM_FN_TARGETS=($(bazel query "kind(sh_binary, attr('generator_function', 'run_krm_fns', {{expr}}))"))
  for target in "${KRM_FN_TARGETS[@]}"
  do
    {{run}} "$target" -- {{resultsdir}}
  done
  just fmt-manifests

# rebuilds static assets for the gopherage CLI and copy it into source control
update-gopherage:
  #!/usr/bin/env bash
  set -eux
  bazel build --config=quiet third_party/gopherage/cmd/html/ts:all
  in=bazel-bin/third_party/gopherage/cmd/html/ts/browser_bundle.js
  out=third_party/gopherage/cmd/html/static/browser_bundle.es2015.js
  cp "$in" "$out"
  chmod 644 "$out"

# re-generates filegroup with all of our KRM functions in it
update-krm-fn-filegroup:
  # reset list so we can rebuild it
  {{run}} tools/deps:buildozer "remove data" //:krm_fns
  # regenerate list based on contents of {{krm_fns_dir}}
  for fn in {{krm_fns_dir}}/*; \
    do {{run}} tools/deps:buildozer "add data //$fn" //:krm_fns; \
  done

################################################################################
# BUILD
################################################################################

# runs all container_test targets in this repo
test-containers:
  bazel test --config=tools-containers $(bazel query 'kind(container_test, //...)')

# builds and publishes all tooling / build containers in this repo
publish-tools-containers:
  just push hack/build -bazel-configs=tools-containers,quiet
  just push tools/containers -bazel-configs=tools-containers,quiet

# builds GraphQL schema documentation in HTML format
graphdoc:
  bazel run @npm//@2fd/graphdoc/bin:graphdoc -- -e https://dev0.edge-preprod.dev/api/v2 -o $(pwd)/graphdoc-output -f

################################################################################
# RELEASE & INSTALL
################################################################################

# publishes binaries to GCS
publish-binaries:
  {{ run }} hack/release:push_edge_tarballs

# publishes platform manifests to GS
publish-manifests:
  {{ run }} hack/release/push_manifest_tarball

# install one or more edge binaries to your machine at {{bin_dir}}. set fetch_bin=true to pull from GCS instead of building from source
install +BINARIES="":
  #!/usr/bin/env bash
  if [[ "{{fetch_bin}}" == "true" ]]; then
    ./hack/build/install-from-gcs.sh {{BINARIES}}
  else
    ./hack/build/install-from-source.sh {{BINARIES}}
  fi

# deploys a release to an edge instance
# TODO: parameterize for other instances
deploy:
  #!/usr/bin/env bash
  ./hack/release/deploy-artifact.sh $(cat ./config/instance/stage0/.version)

# creates an sql database migration file
create-migration name:
  go install -tags 'postgres' github.com/golang-migrate/migrate/v4/cmd/migrate@latest
  migrate create -ext sql -dir cmd/edge-sql/migrations -seq {{name}}