#!/usr/bin/env bash
# Build step for the Render web service. Any non-zero exit fails the deploy,
# which is what we want.
#
# Bundle and assets only. The database work — db:prepare, and the Solid schema
# load that db:prepare skips — runs in render.yaml's preDeployCommand, after the
# build and before the new instance starts, so a failed migration stops the
# deploy while the previous instance keeps serving.
set -o errexit
set -o pipefail
set -o nounset

bundle install
bundle exec rails assets:precompile
bundle exec rails assets:clean
