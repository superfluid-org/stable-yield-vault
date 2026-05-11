.PHONY: echidna-smoke echidna-long echidna-clean

ECHIDNA_TARGET := test/echidna/EchidnaStableYieldVault.sol
ECHIDNA_CONTRACT := EchidnaStableYieldVault
ECHIDNA_ENV := FOUNDRY_PROFILE=echidna

echidna-smoke:
	$(ECHIDNA_ENV) echidna $(ECHIDNA_TARGET) --contract $(ECHIDNA_CONTRACT) --config echidna.yaml

echidna-long:
	$(ECHIDNA_ENV) echidna $(ECHIDNA_TARGET) --contract $(ECHIDNA_CONTRACT) --config echidna.yaml \
		--test-limit 1000000 --seq-len 100

echidna-clean:
	rm -rf echidna-corpus echidna-coverage crytic-export
