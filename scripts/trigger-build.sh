#!/usr/bin/env bash
# Kick off a build immediately instead of waiting for the next CronJob tick.
set -euo pipefail
NS="${NS:-archrepo}"
JOB="manual-$(date +%s)"
kubectl -n "$NS" create job "$JOB" --from=cronjob/archrepo-builder
echo "Created job $JOB — follow logs with:"
echo "  kubectl -n $NS logs -f job/$JOB"
