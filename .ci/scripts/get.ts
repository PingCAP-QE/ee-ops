import * as flags from "https://deno.land/std@0.147.0/flags/mod.ts";
import * as yaml from "https://deno.land/std@0.147.0/encoding/yaml.ts";
import * as base64 from "https://deno.land/std@0.147.0/encoding/base64.ts";
import { sprintf } from "https://deno.land/std@0.147.0/fmt/printf.ts";
import { Octokit, App } from "https://cdn.skypack.dev/octokit?dts";

const DEFAULT_CI_DIR = ".ci";
const DEFAULT_CI_MANIFEST_OUTPUT = "ci.yaml"

/**
 * typescript style guide: https://google.github.io/styleguide/tsguide.html
 */

interface cliParams {
    appId: number;
    privateKeyPath: string;
    gitUrl: string;
    sha: string;
    ciDir?: string;
    output?: string;
}

interface ciFileBlob {
    file_sha: string;
    path: string;
    content: string;
}

function parseRepo(gitUrl: string): { repo: string, owner: string } {
    const [owner, repo] = new URL(gitUrl).
        pathname.
        replace(/^(\/)/, '').
        replace(/(\.git)$/, '').
        split('/', 2)
    return { owner, repo };
}

async function getRepoOctokit(
    app: App,
    owner: string,
    repo: string,
): Promise<Octokit> {
    let ret: Octokit;

    const fullRepoName = sprintf('%s/%s', owner, repo);
    await app.eachRepository(({ octokit, repository }) => {
        if (repository.full_name === fullRepoName) {
            ret = octokit;
        }
    });

    return ret;
}

async function getCiFiles(
    octokit: Octokit,
    owner: string,
    repo: string,
    sha: string,
    dir: string,
): Promise<ciFileBlob[]> {
    // get tree path
    const { data: { tree: dirs } } = await octokit.rest.git.getTree({
        owner: owner,
        repo: repo,
        tree_sha: sha,
    });

    // find dir
    const matched = dirs.find(
        (e: { path?: string; type?: string; sha: string }) => {
            return e.path === dir && e.type === "tree";
        },
    );

    if (!matched) {
        return Promise.resolve([])
    }

    // get files
    const { data: { tree } } = await octokit.rest.git.getTree({
        owner: owner,
        repo: repo,
        tree_sha: matched.sha,
        recursive: true,
    });

    return await Promise.all(tree.
        filter((f: { path: string; }) => f.path.endsWith(".yaml") || f.path.endsWith(".yml")).
        map(async (f: { sha: string; path: string; }) => {
            const { data: { content } } = await octokit.rest.git.getBlob({ owner, repo, file_sha: f.sha });
            const file_content = new TextDecoder().decode(base64.decode(content));
            return { path: f.path, file_sha: f.sha, content: file_content } as ciFileBlob;
        })
    );
}

async function main({
    ciDir = DEFAULT_CI_DIR,
    output = DEFAULT_CI_MANIFEST_OUTPUT,
    appId, privateKeyPath, gitUrl, sha,
}: cliParams) {
    const { owner, repo } = parseRepo(gitUrl);

    // decode private key from base64 encoded string
    const privateKey = await Deno.readTextFile(privateKeyPath);
    const app = new App({ appId, privateKey });
    const { data: { slug } } = await app.octokit.rest.apps.getAuthenticated();
    console.debug({ slug, owner, repo });

    const files = await getCiFiles(
        await getRepoOctokit(app, owner, repo),
        owner,
        repo,
        sha,
        ciDir,
    );

    await Deno.writeFile(output, new TextEncoder().encode(yaml.stringify(files)))
}

const cliArgs = flags.parse(Deno.args) as cliParams;
await main(cliArgs);
console.log("~~~~~~~~~~~end~~~~~~~~~~~~~~");
/**
 * FIXME: A bug in [octokit](https://github.com/octokit/octokit.j).
 * current I need call an `exit` at the end of deno script.
 * issue: https://github.com/octokit/octokit.js/issues/2079
 * working in progress: https://github.com/octokit/webhooks.js/pull/693
 */
Deno.exit(0);