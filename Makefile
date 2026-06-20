# Fully in-cluster workflow — no image build, no registry.
# The build logic + PKGBUILDs are shipped to the cluster as ConfigMaps.
NS ?= archrepo

.PHONY: sync deploy secret trigger logs status clean-jobs

sync:                        ## Ship build script + PKGBUILDs into the cluster as ConfigMaps
	kubectl create namespace $(NS) --dry-run=client -o yaml | kubectl apply -f -
	kubectl -n $(NS) create configmap archrepo-build-script \
	  --from-file=build-repo.sh=builder/scripts/build-repo.sh \
	  --dry-run=client -o yaml | kubectl apply -f -
	@tmp=$$(mktemp -d); tar czf $$tmp/src.tar.gz pkgbuilds nvchecker; \
	kubectl -n $(NS) create configmap archrepo-src \
	  --from-file=src.tar.gz=$$tmp/src.tar.gz \
	  --dry-run=client -o yaml | kubectl apply -f -; \
	rm -rf $$tmp
	@echo "ConfigMaps updated. Run 'make trigger' to build now."

secret:                      ## Generate GPG key + create the archrepo-gpg Secret
	./scripts/create-gpg-secret.sh

deploy: sync                 ## Apply all manifests (also syncs ConfigMaps)
	kubectl apply -f k8s/00-namespace.yaml
	kubectl apply -f k8s/10-pvc.yaml
	kubectl apply -f k8s/30-cronjob.yaml
	kubectl apply -f k8s/40-nginx.yaml
	kubectl apply -f k8s/50-ingress.yaml

trigger:                     ## Run a build now (don't wait for the cron tick)
	./scripts/trigger-build.sh

logs:                        ## Tail the most recent builder job
	kubectl -n $(NS) logs -f --tail=200 \
	  $$(kubectl -n $(NS) get pods -l 'batch.kubernetes.io/job-name' \
	     --sort-by=.metadata.creationTimestamp -o name | tail -1)

status:                      ## Show pods, jobs, ingress, pvc
	kubectl -n $(NS) get pods,jobs,cronjob,ingress,pvc,configmap

clean-jobs:                  ## Delete finished manual jobs
	kubectl -n $(NS) delete jobs --field-selector status.successful=1 || true
