REPO_DIR=repo
CHART_DIR=charts
CHARTS=$(shell cd $(CHART_DIR) && find . -maxdepth 1 -mindepth 1 -type d)

CHART_TARBALLS=$(CHARTS:%=$(REPO_DIR)/%.tgz)

.PHONY: repository
repository: $(REPO_DIR)/index.yaml

$(REPO_DIR):
	mkdir $(REPO_DIR)

.SECONDEXPANSION:
$(REPO_DIR)/%.tgz: $$(shell find $$(CHART_DIR)/$$* -type f) | $(REPO_DIR)
	[ "$(basename $(notdir $@))" = "$$(yq '.name' $(CHART_DIR)/$(basename $(notdir $@))/Chart.yaml)-$$(yq '.version' $(CHART_DIR)/$(basename $(notdir $@))/Chart.yaml)" ]
	[ "$$(yq '.version' $(CHART_DIR)/$(basename $(notdir $@))/Chart.yaml)" = "$$(yq '.appVersion' $(CHART_DIR)/$(basename $(notdir $@))/Chart.yaml)" ]
	$$(yq '.icon != null' $(CHART_DIR)/$(basename $(notdir $@))/Chart.yaml)
	stat ./olm/$(shell yq '.icon' $(CHART_DIR)/$(basename $(notdir $@))/Chart.yaml)
	helm package $(CHART_DIR)/$(basename $(notdir $@)) -d $(REPO_DIR) --dependency-update

$(REPO_DIR)/index.yaml: $(CHART_TARBALLS) $(REPO_DIR)
	cd $(REPO_DIR) && helm repo index .

clean:
	rm -rf $(REPO_DIR)
