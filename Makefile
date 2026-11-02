.PHONY: check package clean

check:
	./scripts/check.sh

package: check
	./scripts/package-release.sh

clean:
	rm -rf dist
