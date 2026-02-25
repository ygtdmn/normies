import { renderSvg } from "./svg.js";
import { decodeTraits, countPixels } from "./traits.js";

export interface CanvasMetadataInfo {
    actionPoints: number;
    level: number;
    customized: boolean;
    originalPixelCount: number;
}

/**
 * Build full NFT metadata JSON matching NormiesRendererV4.tokenURI output.
 * When canvasInfo is provided, includes canvas-aware attributes (Level, Action Points, Customized).
 * The imageData should be the composited bitmap (original XOR transform) when customized.
 */
export function buildMetadata(
    tokenId: number,
    imageData: Uint8Array,
    traitsHex: `0x${string}`,
    canvasInfo?: CanvasMetadataInfo
): object {
    const svg = renderSvg(imageData);
    const svgBase64 = Buffer.from(svg).toString("base64");
    const { attributes } = decodeTraits(traitsHex);
    const pixelCount = canvasInfo?.originalPixelCount ?? countPixels(imageData);

    // Build animation_url HTML (matching on-chain _buildAnimationUrl)
    const imageHex = Buffer.from(imageData).toString("hex");
    const html =
        "<html><body style='margin:0;overflow:hidden;width:100vw;height:100vh;" +
        "display:flex;align-items:center;justify-content:center;background:#e3e5e4'>" +
        "<canvas id='c' width='2000' height='2000' style='image-rendering:pixelated;" +
        "width:min(100vw,100vh);height:min(100vw,100vh)'></canvas>" +
        "<script>var h='" + imageHex + "';" +
        "var c=document.getElementById('c').getContext('2d');" +
        "c.fillStyle='#e3e5e4';c.fillRect(0,0,2000,2000);c.fillStyle='#48494b';" +
        "for(var y=0;y<40;y++)for(var x=0;x<40;x++){var i=y*40+x," +
        "b=parseInt(h.substr((i>>3)*2,2),16);" +
        "if((b>>(7-(i&7)))&1)c.fillRect(x*50,y*50,50,50)}" +
        "</script></body></html>";
    const htmlBase64 = Buffer.from(html).toString("base64");

    return {
        name: `Normie #${tokenId}`,
        attributes: [
            ...attributes.map((a) => ({ trait_type: a.trait_type, value: a.value })),
            { display_type: "number", trait_type: "Level", value: canvasInfo?.level ?? 1 },
            { display_type: "number", trait_type: "Pixel Count", value: pixelCount },
            { display_type: "number", trait_type: "Action Points", value: canvasInfo?.actionPoints ?? 0 },
            { trait_type: "Customized", value: canvasInfo?.customized ? "Yes" : "No" },
        ],
        image: `data:image/svg+xml;base64,${svgBase64}`,
        animation_url: `data:text/html;base64,${htmlBase64}`,
    };
}
