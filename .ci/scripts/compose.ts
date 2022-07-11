// init compose script
import { parseAll } from "https://deno.land/std@0.147.0/encoding/yaml.ts";

async function readManifest(path: string) {
    const decoder = new TextDecoder("utf-8");

    const data = await Deno.readFile(path);
    const result = parseAll(decoder.decode(data));
    console.debug(result);
}

await readManifest('ci.yaml');