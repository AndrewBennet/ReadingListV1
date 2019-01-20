#! /bin/bash
set -e

brew install mint
mint run yonaskolb/xcodegen
pod install
bundle exec fastlane test

# Deploy on master, if we have access to the necessary secure variables
if [ "${TRAVIS_SECURE_ENV_VARS}" == "true" ] && [ "${TRAVIS_BRANCH}" == "master" ]; then
  bundle exec fastlane deploy
fi