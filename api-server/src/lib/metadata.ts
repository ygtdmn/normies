import { renderSvg } from "./svg.js";
import { decodeTraits, countPixels } from "./traits.js";
import { gridSizeFromLength } from "./bitmap.js";

export interface CanvasMetadataInfo {
    actionPoints: number;
    level: number;
    customized: boolean;
    originalPixelCount: number;
    legendaryCanvasArtist?: string | null;
    gridSize?: number;
    baseCleared?: boolean;
}

export interface MetadataAttribute {
    trait_type: string;
    value: string | number;
    display_type?: string;
}

const CELL_PX = 50;

/**
 * Build full NFT metadata JSON matching NormiesRendererV6.tokenURI output.
 * When canvasInfo is provided, includes canvas-aware attributes (Level, Action Points, Customized,
 * Canvas Size, Blank Canvas). The imageData should be the composited bitmap at the token's grid size.
 */
export function buildMetadata(
    tokenId: number,
    imageData: Uint8Array,
    traitsHex: `0x${string}`,
    canvasInfo?: CanvasMetadataInfo
): object {
    const { attributes } = decodeTraits(traitsHex);
    const pixelCount = canvasInfo?.originalPixelCount ?? countPixels(imageData);
    return buildMetadataFromAttributes(
        tokenId,
        imageData,
        attributes.map((a) => ({ trait_type: a.trait_type, value: a.value })),
        canvasInfo,
        pixelCount
    );
}

export function buildMetadataFromAttributes(
    tokenId: number,
    imageData: Uint8Array,
    attributes: MetadataAttribute[],
    canvasInfo?: Omit<CanvasMetadataInfo, "originalPixelCount">,
    pixelCountOverride?: number
): object {
    const svg = renderSvg(imageData);
    const svgBase64 = Buffer.from(svg).toString("base64");
    const pixelCount = pixelCountOverride ?? countPixels(imageData);
    const gridSize = canvasInfo?.gridSize ?? gridSizeFromLength(imageData.length);

    // Build animation_url HTML (matching on-chain _buildAnimationUrl)
    const imageHex = Buffer.from(imageData).toString("hex");
    const px = gridSize * CELL_PX;
    const html =
        "<html><body style='margin:0;overflow:hidden;width:100vw;height:100vh;" +
        "display:flex;align-items:center;justify-content:center;background:#e3e5e4'>" +
        "<canvas id='c' width='" + px + "' height='" + px + "' style='image-rendering:pixelated;" +
        "width:min(100vw,100vh);height:min(100vw,100vh)'></canvas>" +
        "<script>var h='" + imageHex + "',n=" + gridSize + ",s=" + CELL_PX + ";" +
        "var c=document.getElementById('c').getContext('2d');" +
        "c.fillStyle='#e3e5e4';c.fillRect(0,0,n*s,n*s);c.fillStyle='#48494b';" +
        "for(var y=0;y<n;y++)for(var x=0;x<n;x++){var i=y*n+x," +
        "b=parseInt(h.substr((i>>3)*2,2),16);" +
        "if((b>>(7-(i&7)))&1)c.fillRect(x*s,y*s,s,s)}" +
        "</script></body></html>";
    const htmlBase64 = Buffer.from(html).toString("base64");

    return {
        name: `Normie #${tokenId}`,
        attributes: [
            ...attributes.map((a) => (
                a.display_type
                    ? { display_type: a.display_type, trait_type: a.trait_type, value: a.value }
                    : { trait_type: a.trait_type, value: a.value }
            )),
            { display_type: "number", trait_type: "Level", value: canvasInfo?.level ?? 1 },
            ...(canvasInfo?.legendaryCanvasArtist
                ? [{ trait_type: "Legendary Canvas", value: canvasInfo.legendaryCanvasArtist }]
                : []),
            { display_type: "number", trait_type: "Pixel Count", value: pixelCount },
            { display_type: "number", trait_type: "Action Points", value: canvasInfo?.actionPoints ?? 0 },
            { trait_type: "Customized", value: canvasInfo?.customized ? "Yes" : "No" },
            { trait_type: "Canvas Size", value: `${gridSize}x${gridSize}` },
            { trait_type: "Blank Canvas", value: canvasInfo?.baseCleared ? "Yes" : "No" },
        ],
        image: `data:image/svg+xml;base64,${svgBase64}`,
        animation_url: `data:text/html;base64,${htmlBase64}`,
    };
}
