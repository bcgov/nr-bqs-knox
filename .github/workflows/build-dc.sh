#!/usr/bin/env bash

echo "===> Create Intention"
# Start with empty actions array, then add one action per service
cat ./.github/workflows/build-dc.json | jq "\
    .event.reason=\"${EVENT_REASON}\" | \
    .event.url=\"https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}\" | \
    .actions = [] \
    " > intention.json

# Add action for nr-bqs-knox
jq "\
    .actions += [{
      \"action\": \"package-build\",
      \"id\": \"dcbuild_0\",
      \"provision\": [],
      \"service\": {
        \"project\": \"oscar\",
        \"name\": \"nr-bqs-knox\",
        \"environment\": \"tools\"
      },
      \"package\": {
        \"category\": \"infrastructure\",
        \"version\": \"${PACKAGE_VERSION#d}\",
        \"buildGuid\": \"${PACKAGE_BUILD_GUID}\",
        \"buildVersion\": \"${PACKAGE_BUILD_VERSION}\",
        \"buildNumber\": ${PACKAGE_BUILD_NUMBER},
        \"name\": \"nr-bqs-knox-dc\",
        \"type\": \"oci-archive\",
        \"license\": \"Apache-2.0\"
      }
    }] \
    " intention.json > intention.tmp && mv intention.tmp intention.json

