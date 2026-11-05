#!/usr/bin/env bash

echo "===> Create Intention"
# Create intention
cat ./.github/workflows/build-intention-nr-bqs-knox.json | jq "\
    .event.reason=\"${EVENT_REASON}\" | \
    .event.url=\"https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}\" | \
    (.actions[] | select(.id == \"build\") .package.version) |= \"${PACKAGE_VERSION}\" | \
    (.actions[] | select(.id == \"build\") .package.buildGuid) |= \"${PACKAGE_BUILD_GUID}\" | \
    (.actions[] | select(.id == \"build\") .package.buildVersion) |= \"${PACKAGE_BUILD_VERSION}\" | \
    (.actions[] | select(.id == \"build\") .package.type) |= \"${PACKAGE_TYPE}\" | \
    (.actions[] | select(.id == \"build\") .package.buildNumber) |= ${PACKAGE_BUILD_NUMBER} \
    " > intention.json