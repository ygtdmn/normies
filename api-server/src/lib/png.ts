import { Resvg } from "@resvg/resvg-js";
import { PNG_OUTPUT_SIZE } from "../config.js";

export function svgToPng(svg: string): Buffer {
    const resvg = new Resvg(svg, {
        fitTo: { mode: "width", value: PNG_OUTPUT_SIZE },
    });
    const rendered = resvg.render();
    return Buffer.from(rendered.asPng());
}
