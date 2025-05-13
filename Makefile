REPO_DIR=repo
CHART_DIR=charts
CHARTS=$(shell cd $(CHART_DIR) && find . -maxdepth 1 -mindepth 1 -type d)
SUPPORT_MATRIX_CHECKS?=true

CHART_TARBALLS=$(CHARTS:%=$(REPO_DIR)/%.tgz)

.PHONY: repository
repository: $(REPO_DIR)/index.yaml

$(REPO_DIR):
	mkdir $(REPO_DIR)

.SECONDEXPANSION:
$(REPO_DIR)/%.tgz: $$(shell find $$(CHART_DIR)/$$* -type f) | $(REPO_DIR)
ifeq (${SUPPORT_MATRIX_CHECKS},true)
	[ "$(basename $(notdir $@))" = "$$(yq -r '.name' $(CHART_DIR)/$(basename $(notdir $@))/Chart.yaml)-$$(yq -r '.version' $(CHART_DIR)/$(basename $(notdir $@))/Chart.yaml)" ]
	[ "$$(yq -r '.version' $(CHART_DIR)/$(basename $(notdir $@))/Chart.yaml)" = "$$(yq -r '.appVersion' $(CHART_DIR)/$(basename $(notdir $@))/Chart.yaml)" ]
	yq -r -e '.kubeVersion' $(CHART_DIR)/$(basename $(notdir $@))/Chart.yaml
	grep "$$(yq -r '.name' $(CHART_DIR)/$(basename $(notdir $@))/Chart.yaml)[[:space:]]*|[[:space:]].*$$(yq -r '.version' $(CHART_DIR)/$(basename $(notdir $@))/Chart.yaml).*|$$" README.md
endif
	stat $(CHART_DIR)/$(basename $(notdir $@))/values.yaml
	$$(yq -r '.icon != null' $(CHART_DIR)/$(basename $(notdir $@))/Chart.yaml)
	stat ./olm/$(shell yq -r '.icon' $(CHART_DIR)/$(basename $(notdir $@))/Chart.yaml)
	helm package $(CHART_DIR)/$(basename $(notdir $@)) -d $(REPO_DIR) --dependency-update

$(REPO_DIR)/index.yaml: $(CHART_TARBALLS) $(REPO_DIR)
	cd $(REPO_DIR) && helm repo index .

clean:
	rm -rf $(REPO_DIR)
