import * as yaml from "https://deno.land/std@0.147.0/encoding/yaml.ts";
import * as flags from "https://deno.land/std@0.147.0/flags/mod.ts";
import { sprintf } from "https://deno.land/std@0.147.0/fmt/printf.ts";

const DEFAULT_CI_MANIFEST_INPUT = "ci.yaml";

interface ciFileBlob {
    file_sha: string;
    path: string;
    content: string;
}

interface prInfo {
    number: number;
    user: string;
    headOwner: string;
    headRepo: string;
    headRef: string;
    baseOwner: string;
    baseRepo: string;
    baseRef: string;
}

interface cliParams {
    gitUrl: string;
    input?: string; // default ci.yaml
    pr: prInfo;
}

interface pipelineRun {
    [key: string]: any;
}
interface triggerTemplate {
    kind: "TriggerTemplate";
    metadata: {
        name: string;
        [key: string]: any;
    };
    spec: { [key: string]: any };
    [key: string]: any;
}
interface trigger {
    kind: "Trigger";
    metadata: {
        name: string;
        [key: string]: any;
    };
    spec: { [key: string]: any };
    [key: string]: any;
}

function parseRepo(gitUrl: string): { repo: string; owner: string } {
    const [owner, repo] = new URL(gitUrl)
        .pathname
        .replace(/^(\/)/, "")
        .replace(/(\.git)$/, "")
        .split("/", 2);
    return { owner, repo };
}

function readManifest(path: string) {
    const content = Deno.readTextFileSync(path);
    return yaml.parse(content) as ciFileBlob[];
}

function composeTriggerTemplate(run: pipelineRun, pr: prInfo): triggerTemplate {
    const ret: triggerTemplate = {
        apiVersion: "triggers.tekton.dev/v1beta1",
        kind: "TriggerTemplate",
        metadata: {
            name: "github-template-owner-repo-pr-12345",
            labels: {
                type: "github-pr",
                prNum: pr.number,
                prOwner: pr.baseOwner,
                prRepo: pr.baseRepo,
            },
        },
        spec: {
            params: [
                {
                    name: "git-url",
                    description: "The git repository full url",
                },
                {
                    name: "git-revision",
                    default: "main",
                    description: "The git revision",
                },
            ],
            resourcetemplates: [run],
        },
    };

    return ret;
}

function composeTrigger(templateName: string, pr: prInfo): trigger {
    const filterFormat = `\
        header.match('X-GitHub-Event', 'pull_request') && \
        body.action in ['opened', 'synchronize'] && \
        body.pull_request.base.user.login == %s && \
        body.pull_request.base.repo.name == %s && \
        body.pull_request.number == %d`;

    const filter = sprintf(filterFormat, pr.baseOwner, pr.baseRepo, pr.number);
    const ret: trigger = {
        apiVersion: "triggers.tekton.dev/v1beta1",
        kind: "Trigger",
        metadata: {
            name: "github-template-owner-repo-pr-12345",
            labels: {
                // TODO(wuhuizuo): label value should be 63 characters or less. 
                type: "github-pr",
                prNum: pr.number,
                prOwner: pr.baseOwner,
                prRepo: pr.baseRepo,
            },
        },
        spec: {
            bindings: [{ ref: "github-pr" }],
            template: {
                ref: templateName,
            },
            interceptors: [
                {
                    ref: { name: "cel" },
                    params: [
                        {
                            name: "filter",
                            value: filter,
                        },
                    ],
                },
            ],
        },
    };

    return ret;
}

function main({ input, gitUrl, pr }: cliParams) {
    if (!input) {
        input = DEFAULT_CI_MANIFEST_INPUT;
    }
    const pipelines = readManifest(input);

    if (!pr.baseOwner || !pr.baseRepo) {
        const { owner, repo } = parseRepo(gitUrl);
        pr.baseOwner = owner;
        pr.baseRepo = repo;
    }
    pipelines.forEach((e) => {
        const ePipelineRun = yaml.parse(e.content) as pipelineRun;
        const eTriggerTemplate = composeTriggerTemplate(ePipelineRun, pr);
        const eTrigger = composeTrigger(eTriggerTemplate.metadata.name, pr);

        console.log(yaml.stringify(eTriggerTemplate));
        console.log(yaml.stringify(eTrigger));
    });
}

const cliArgs = flags.parse(Deno.args) as cliParams;
main(cliArgs);
console.log("~~~~~~~~~~~end~~~~~~~~~~~~~~");
/**
 * FIXME: A bug in [octokit](https://github.com/octokit/octokit.j).
 * current I need call an `exit` at the end of deno script.
 * issue: https://github.com/octokit/octokit.js/issues/2079
 * working in progress: https://github.com/octokit/webhooks.js/pull/693
 */
//  Deno.exit(0);