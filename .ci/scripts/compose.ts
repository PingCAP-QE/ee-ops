import * as yaml from "https://deno.land/std@0.147.0/encoding/yaml.ts";
import * as flags from "https://deno.land/std@0.147.0/flags/mod.ts";

const DEFAULT_CI_MANIFEST_INPUT = "ci.yaml"

interface ciFileBlob {
    file_sha: string;
    path: string;
    content: string;
}

interface cliParams {
    input?: string; // default ci.yaml
}

interface pipelineRun { [key: string]: any }
interface triggerTemplate { [key: string]: any }

function readManifest(path: string) {
    const content = Deno.readTextFileSync(path);
    return yaml.parse(content) as ciFileBlob[];
}

function composeTriggerTemplate(run: pipelineRun): triggerTemplate {
    const ret: triggerTemplate = {
        apiVersion: 'triggers.tekton.dev/v1beta1',
        kind: 'TriggerTemplate',
        metadata: {
            name: 'github-template-owner-repo-pr-12345',
            labels: {
                type: 'github-pr',
                prNum: 12345,
                prOwner: 'PingCAP-QE',
                prRepo: 'ee-ops',
            }
        },
        spec: {
            params: [
                {
                    name: 'git-url',
                    description: 'The git repository full url'
                },
                {
                    name: 'git-revision',
                    default: 'main',
                    description: 'The git revision'
                }
            ],
            resourcetemplates: [run]
        }
    };

    return ret;
}

function main({ input }: cliParams) {
    if (!input) {
        input = DEFAULT_CI_MANIFEST_INPUT
    }
    const pipelines = readManifest(input);

    pipelines.forEach(e => {
        const ePipelineRun = yaml.parse(e.content) as pipelineRun;
        const eTriggerTemplate = composeTriggerTemplate(ePipelineRun);

        console.log(yaml.stringify(eTriggerTemplate))
    });
}

const cliArgs = flags.parse(Deno.args) as cliParams;
main(cliArgs);
console.log("~~~~~~~~~~~end~~~~~~~~~~~~~~");

