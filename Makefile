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
	sh check-chart.sh $(CHART_DIR)/$(basename $(notdir $@))
	helm package $(CHART_DIR)/$(basename $(notdir $@)) -d $(REPO_DIR) --dependency-update

$(REPO_DIR)/index.yaml: $(CHART_TARBALLS) $(REPO_DIR)
	cd $(REPO_DIR) && helm repo index .

clean:
	rm -rf $(REPO_DIR)
