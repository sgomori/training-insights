#!/usr/bin/env bash
# Build step for the Render web service. Any non-zero exit fails the deploy,
# which is what we want — a half-migrated instance is worse than no deploy.
set -o errexit
set -o pipefail
set -o nounset

bundle install
bundle exec rails assets:precompile
bundle exec rails assets:clean

# Loads the Solid Cache, Queue, and Cable schemas alongside the app's own on
# first deploy, then applies pending migrations on subsequent ones.
bundle exec rails db:prepare
