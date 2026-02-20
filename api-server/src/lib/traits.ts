import { hexToBytes } from "viem";

// Trait label arrays matching NormiesTraits.sol exactly (title case)
const TRAIT_CATEGORIES = [
    {
        name: "Type",
        values: ["Human", "Cat", "Alien", "Agent"],
    },
    {
        name: "Gender",
        values: ["Male", "Female", "Non-Binary"],
    },
    {
        name: "Age",
        values: ["Young", "Middle-Aged", "Old"],
    },
    {
        name: "Hair Style",
        values: [
            "Short Hair", "Long Hair", "Curly Hair", "Straight Hair", "Wavy Hair",
            "Spiky Hair", "Wild Hair", "Messy Hair", "Mohawk", "Crazy Hair",
            "Braided Hair", "Bald", "Ponytail", "Pigtails", "Afro", "Buzz Cut",
            "Frumpy Hair", "Stringy Hair", "Peak Spike", "Half Shaved", "Knitted Cap",
        ],
    },
    {
        name: "Facial Feature",
        values: [
            "Full Beard", "Mustache", "Goatee", "Chin Strap", "Muttonchops",
            "Shadow Beard", "Luxurious Beard", "Handlebars", "Big Beard", "Normal Beard",
            "Clean Shaven", "Freckles", "Mole", "Rosy Cheeks", "Dimples",
            "High Cheekbones", "Spots",
        ],
    },
    {
        name: "Eyes",
        values: [
            "Classic Shades", "Big Shades", "Regular Shades", "Small Shades",
            "Horned Rim Glasses", "Nerd Glasses", "VR Headset", "3D Glasses",
            "Eye Mask", "Eye Patch", "Round Glasses", "Square Glasses", "Aviators",
            "No Glasses",
        ],
    },
    {
        name: "Expression",
        values: ["Neutral", "Slight Smile", "Serious", "Content", "Peaceful", "Confident", "Friendly"],
    },
    {
        name: "Accessory",
        values: [
            "Top Hat", "Fedora", "Cowboy Hat", "Beanie", "Cap", "Cap Forward",
            "Bandana", "Headband", "Do-Rag", "Hoodie", "Earring", "Gold Chain",
            "Silver Chain", "Bow Tie", "No Accessories",
        ],
    },
];

export interface TraitAttribute {
    trait_type: string;
    value: string;
}

export interface TraitsResult {
    raw: `0x${string}`;
    attributes: TraitAttribute[];
}

export function decodeTraits(traitsHex: `0x${string}`): TraitsResult {
    const bytes = hexToBytes(traitsHex);

    const attributes: TraitAttribute[] = TRAIT_CATEGORIES.map((category, i) => {
        const index = bytes[i];
        const value = category.values[index];
        if (value === undefined) {
            throw new Error(`Invalid trait index ${index} for category "${category.name}"`);
        }
        return { trait_type: category.name, value };
    });

    return { raw: traitsHex, attributes };
}

/**
 * Count set bits in the image data (pixel count).
 * Mirrors NormiesRendererV3._countPixels — Kernighan's algorithm.
 */
export function countPixels(imageData: Uint8Array): number {
    let count = 0;
    for (let i = 0; i < 200; i++) {
        let b = imageData[i];
        while (b !== 0) {
            b &= b - 1;
            count++;
        }
    }
    return count;
}
