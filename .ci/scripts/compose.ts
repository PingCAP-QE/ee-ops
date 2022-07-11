// init compose script
import { parse as parseYaml, stringify as stringifyYaml } from "https://deno.land/std@0.147.0/encoding/yaml.ts";

interface ciFileBlob {
    file_sha: string;
    path: string;
    content: string;
}

interface pipelineRun { [key: string]: any }
interface triggerTemplate { [key: string]: any }

async function readManifest(path: string) {
    const decoder = new TextDecoder("utf-8");

    const data = await Deno.readFile(path);
    const result = parseYaml(decoder.decode(data)) as ciFileBlob[];

    result.forEach(e => {
        const ePipelineRun = parseYaml(e.content) as pipelineRun;
        const eTriggerTemplate = composeTriggerTemplate(ePipelineRun);

        console.log(stringifyYaml(eTriggerTemplate))
    });
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

await readManifest('ci.yaml');