#!/usr/bin/env node
import { runHealthcheck } from "../healthcheck.js";

process.exitCode = runHealthcheck();
