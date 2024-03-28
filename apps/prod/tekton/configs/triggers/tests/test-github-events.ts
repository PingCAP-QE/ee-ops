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

async function generateEventPayload(
  gitUrl: string,
  ref: string,
): Promise<Payload> {
  const url = new URL(gitUrl);
  const owner = url.pathname.split("/")[1];
  const repoName = url.pathname.split("/").pop()?.replace(/\.git$/, "");
  const isTag = ref.startsWith("refs/tags/");
  const refName = isTag ? ref.replace("refs/tags/", "") : ref;

  const payload: Payload = {
    ref: refName,
    ref_type: isTag ? "tag" : "branch",
    repository: {
      name: repoName!,
      full_name: `${owner}/${repoName}`,
      owner: {
        login: owner,
      },
      clone_url: gitUrl,
    },
  };

  if (!isTag) {
    const lastCommitSha = await getCommitSha(owner, repoName!, ref);
    payload.before = "0000000000000000000000000000000000000000";
    payload.after = lastCommitSha;
  }

  return payload;
}

async function sendEvent(
  gitUrl: string,
  ref: string,
  eventUrl: string,
): Promise<void> {
  const payload = await generateEventPayload(gitUrl, ref);
  const eventType = payload.ref_type === "branch" ? "push" : "create";

  console.debug(payload);

  const response = await fetch(eventUrl, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-GitHub-Event": eventType,
    },
    body: JSON.stringify(payload),
  });

  if (!response.ok) {
    console.error(`Request failed with status ${response.status}`);
    Deno.exit(1);
  }

  console.log("Request succeeded");
}

async function main() {
  const args = parseArgs(Deno.args);
  const gitUrl = args.url;
  const ref = args.ref || "refs/heads/master";
  const eventUrl = args.eventUrl || "https://example.com";

  if (!gitUrl) {
    console.error(
      "Usage: deno run script.ts --url <git-url> [--ref <ref>] [--eventUrl <event-url>]",
    );
    Deno.exit(1);
  }

  await sendEvent(gitUrl, ref, eventUrl);
}

await main();
