import cron from "node-cron";
import config from "config";
import Archethic from "@archethicjs/sdk";
import { Level } from "level";
import express from "express";
import Debug from "debug";

import { tick as tickArchethic } from "./src/archethic.js";
import { tick as tickEVM } from "./src/evm.js";

const debug = Debug("server");
const ENDPOINT = config.get("archethic.endpoint");
let METRICS_ARCHETHIC = [];
let METRICS_EVM = [];

debug(`Connecting to endpoint ${ENDPOINT}...`);
const archethic = new Archethic(ENDPOINT);
await archethic.connect();
debug(`Connected!`);

const dbFolder = config.get("dbFolder");
debug(`Opening database: ${dbFolder}...`);
const db = new Level(dbFolder, { valueEncoding: "json" });
await db.open();
debug(`Opened!`);

const app = express();
const port = config.get("port");

app.get("/metrics", (req, res) => {
  let text = "";
  let prevMetricsBaseName = "";

  // metrics with the same name but different labels must appear grouped
  const sortedMetrics = [...METRICS_ARCHETHIC, ...METRICS_EVM].sort((a, b) => {
    if (a.name > b.name) return 1;
    return -1;
  });

  for (const metric of sortedMetrics) {
    const metricBaseName = metric.name.split("{")[0];

    // the type must not be set on each metrics
    if (metricBaseName != prevMetricsBaseName) {
      text += `# TYPE ${metricBaseName} gauge\n`;
    }

    text += `${metric.name} ${metric.value}\n`;
    prevMetricsBaseName = metricBaseName;
  }

  if (req.get("accept").includes("html")) {
    res.send(`<html><body><pre>${text}</pre></body></html>`);
  } else {
    res.send(text);
  }
});

debug(`Starting HTTP server on port ${port}...`);
app.listen(port, () => {
  debug(`Started!`);

  const tick = async function () {
    return Promise.all([tickArchethic(archethic, db), tickEVM(db)]).then(
      ([metricsArchethic, metricsEVM]) => {
        METRICS_ARCHETHIC = metricsArchethic;
        METRICS_EVM = metricsEVM;
        METRICS_EVM.push({
          name: "tick",
          value: Date.now(),
        });
      },
    );
  };

  tick();

  const cronInterval = config.get("cron");
  debug(`Scheduler set to: ${cronInterval}`);
  cron.schedule(cronInterval, async () => {
    debug("tick start");
    await tick();
    debug("tick end");
  });
});
