import { getHTLCs as getEVMHTLCs } from "../registry/evm-htlcs.js";
import { getHTLCs as getArchethicHtlcs } from "../registry/archethic-htlcs.js";
import { HTLC_STATUS } from "../archethic/get-htlc-statuses.js";
import config from "config";

const archethicEndpoint = config.get("archethic.endpoint");

export default function (db) {
  return async (req, res) => {
    const chargeableHTLCs = merge(
      await getArchethicHtlcs(db, "chargeable"),
      await getEVMHTLCs(db, "chargeable"),
      "chargeable",
    );

    const signedHTLCs = merge(
      await getArchethicHtlcs(db, "signed"),
      await getEVMHTLCs(db, "signed"),
      "signed",
    );

    const htlcs = [...chargeableHTLCs, ...signedHTLCs];

    const formatDate = (date) => {
      return (
        date.getUTCFullYear() +
        "-" +
        String(date.getUTCMonth() + 1).padStart(2, "0") +
        "-" +
        String(date.getUTCDate()).padStart(2, "0") +
        "T" +
        String(date.getUTCHours()).padStart(2, "0") +
        ":" +
        String(date.getUTCMinutes()).padStart(2, "0") +
        ":" +
        String(date.getUTCSeconds()).padStart(2, "0") +
        "Z"
      );
    };

    const formatArchethicAddr = (addr) =>
      addr.substr(4, 6) + "..." + addr.substr(-6);

    const formatEvmAddr = (addr) => addr.substr(0, 6) + "..." + addr.substr(-6);

    res.render("htlcs", {
      HTLC_STATUS,
      htlcs,
      formatDate,
      formatArchethicAddr,
      formatEvmAddr,
      archethicEndpoint,
    });
  };
}

function merge(archethicHtlcs, evmHtlcs, type) {
  // dump mumbai
  archethicHtlcs = archethicHtlcs.filter((htlc) => htlc.evmChainID != 80001);

  for (const archethicHtlc of archethicHtlcs) {
    archethicHtlc.type = type;
    if (archethicHtlc.evmContract) {
      const match = evmHtlcs.find(
        (evmHtlc) =>
          evmHtlc.address.toLowerCase() ==
          archethicHtlc.evmContract.toLowerCase(),
      );
      if (match != null) {
        archethicHtlc.evmHtlc = match;
      }
    } else {
      // Try to match based on the locktime (2s tolerance)
      const matches = evmHtlcs.filter(
        (evmHtlc) => Math.abs(evmHtlc.lockTime - archethicHtlc.endTime) < 2,
      );
      if (matches.length == 1) {
        archethicHtlc.evmHtlc = matches[0];
      }
    }
  }
  return archethicHtlcs;
}