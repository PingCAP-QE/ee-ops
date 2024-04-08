#!/usr/bin/env deno run --allow-net

import { parseArgs } from "https://deno.land/std@0.220.1/cli/parse_args.ts";

interface Payload {
  ref: string;
  before?: string;
  after?: string;
  ref_type: string;
  repository: {
    name: string;
    full_name?: string;
    clone_url: string;
    owner: {
      login: string;
    };
  };
}

async function getCommitSha(
  owner: string,
  repo: string,
  ref: string,
): Promise<string> {
  const apiUrl = `https://api.github.com/repos/${owner}/${repo}/commits/${ref}`;
  const response = await fetch(apiUrl);
  const commit = await response.json();
  return commit.sha;
}

async function generatePushEventPayload(
  gitUrl: string,
  ref: string,
) {
  const url = new URL(gitUrl);
  const owner = url.pathname.split("/")[1];
  const repoName = url.pathname.split("/").pop()?.replace(/\.git$/, "");

  return {
    before: "0000000000000000000000000000000000000000",
    after: await getCommitSha(owner, repoName!, ref),
    repository: {
      name: repoName!,
      full_name: `${owner}/${repoName}`,
      owner: {
        login: owner,
      },
      clone_url: gitUrl,
    },
  };
}

function generateCreatePayload(
  gitUrl: string,
  ref: string,
  ref_type = "branch",
) {
  const url = new URL(gitUrl);
  const owner = url.pathname.split("/")[1];
  const repoName = url.pathname.split("/").pop()?.replace(/\.git$/, "");

  return {
    ref,
    ref_type,
    repository: {
      name: repoName!,
      owner: {
        login: owner,
      },
      clone_url: gitUrl,
    },
  };
}

async function sendGithubEvent(
  eventType: string,
  gitUrl: string,
  ref: string,
  eventUrl: string,
): Promise<void> {
  let eventPayload;
  switch (eventType) {
    case "create":
      eventPayload = generateCreatePayload(
        gitUrl,
        ref.replace("refs/tags/", "").replace("refs/heads/", ""),
        ref.startsWith("refs/tags/") ? "tag" : "branch",
      );
      break;
    case "push":
      eventPayload = await generatePushEventPayload(
        gitUrl,
        `refs/heads/${ref.replace("refs/heads/", "")}`,
      );
      break;
    default:
      break;
  }

  const fetchInit = {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-GitHub-Event": eventType,
    },
    body: JSON.stringify(eventPayload),
  };
  console.debug(fetchInit);

  await fetch(eventUrl, fetchInit);
}

async function main() {
  const args = parseArgs(Deno.args);
  const gitUrl = args.url;
  const ref = args.ref || "refs/heads/master";
  const eventUrl = args.eventUrl || "https://example.com";
  const eventType = args.eventType;

  if (!gitUrl) {
    console.error(
      "Usage: deno run script.ts --url <git-url> --eventType push|create [--ref <ref>] [--eventUrl <event-url>]",
    );
    Deno.exit(1);
  }

  await sendGithubEvent(eventType, gitUrl, ref, eventUrl);
}

await main();
