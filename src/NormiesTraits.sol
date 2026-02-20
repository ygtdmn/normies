// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/**
 * @title NormiesTraits
 * @author Normies by Serc (https://x.com/serc1n)
 * @author Smart Contract by Yigit Duman (https://x.com/yigitduman)
 */
library NormiesTraits {
    error InvalidTraitIndex();

    function typeName(uint8 index) internal pure returns (string memory) {
        if (index == 0) return "Human";
        if (index == 1) return "Cat";
        if (index == 2) return "Alien";
        if (index == 3) return "Agent";
        revert InvalidTraitIndex();
    }

    function genderName(uint8 index) internal pure returns (string memory) {
        if (index == 0) return "Male";
        if (index == 1) return "Female";
        if (index == 2) return "Non-Binary";
        revert InvalidTraitIndex();
    }

    function ageName(uint8 index) internal pure returns (string memory) {
        if (index == 0) return "Young";
        if (index == 1) return "Middle-Aged";
        if (index == 2) return "Old";
        revert InvalidTraitIndex();
    }

    function hairStyleName(uint8 index) internal pure returns (string memory) {
        if (index == 0) return "Short Hair";
        if (index == 1) return "Long Hair";
        if (index == 2) return "Curly Hair";
        if (index == 3) return "Straight Hair";
        if (index == 4) return "Wavy Hair";
        if (index == 5) return "Spiky Hair";
        if (index == 6) return "Wild Hair";
        if (index == 7) return "Messy Hair";
        if (index == 8) return "Mohawk";
        if (index == 9) return "Crazy Hair";
        if (index == 10) return "Braided Hair";
        if (index == 11) return "Bald";
        if (index == 12) return "Ponytail";
        if (index == 13) return "Pigtails";
        if (index == 14) return "Afro";
        if (index == 15) return "Buzz Cut";
        if (index == 16) return "Frumpy Hair";
        if (index == 17) return "Stringy Hair";
        if (index == 18) return "Peak Spike";
        if (index == 19) return "Half Shaved";
        if (index == 20) return "Knitted Cap";
        revert InvalidTraitIndex();
    }

    function facialFeatureName(uint8 index) internal pure returns (string memory) {
        if (index == 0) return "Full Beard";
        if (index == 1) return "Mustache";
        if (index == 2) return "Goatee";
        if (index == 3) return "Chin Strap";
        if (index == 4) return "Muttonchops";
        if (index == 5) return "Shadow Beard";
        if (index == 6) return "Luxurious Beard";
        if (index == 7) return "Handlebars";
        if (index == 8) return "Big Beard";
        if (index == 9) return "Normal Beard";
        if (index == 10) return "Clean Shaven";
        if (index == 11) return "Freckles";
        if (index == 12) return "Mole";
        if (index == 13) return "Rosy Cheeks";
        if (index == 14) return "Dimples";
        if (index == 15) return "High Cheekbones";
        if (index == 16) return "Spots";
        revert InvalidTraitIndex();
    }

    function eyesName(uint8 index) internal pure returns (string memory) {
        if (index == 0) return "Classic Shades";
        if (index == 1) return "Big Shades";
        if (index == 2) return "Regular Shades";
        if (index == 3) return "Small Shades";
        if (index == 4) return "Horned Rim Glasses";
        if (index == 5) return "Nerd Glasses";
        if (index == 6) return "VR Headset";
        if (index == 7) return "3D Glasses";
        if (index == 8) return "Eye Mask";
        if (index == 9) return "Eye Patch";
        if (index == 10) return "Round Glasses";
        if (index == 11) return "Square Glasses";
        if (index == 12) return "Aviators";
        if (index == 13) return "No Glasses";
        revert InvalidTraitIndex();
    }

    function expressionName(uint8 index) internal pure returns (string memory) {
        if (index == 0) return "Neutral";
        if (index == 1) return "Slight Smile";
        if (index == 2) return "Serious";
        if (index == 3) return "Content";
        if (index == 4) return "Peaceful";
        if (index == 5) return "Confident";
        if (index == 6) return "Friendly";
        revert InvalidTraitIndex();
    }

    function accessoryName(uint8 index) internal pure returns (string memory) {
        if (index == 0) return "Top Hat";
        if (index == 1) return "Fedora";
        if (index == 2) return "Cowboy Hat";
        if (index == 3) return "Beanie";
        if (index == 4) return "Cap";
        if (index == 5) return "Cap Forward";
        if (index == 6) return "Bandana";
        if (index == 7) return "Headband";
        if (index == 8) return "Do-Rag";
        if (index == 9) return "Hoodie";
        if (index == 10) return "Earring";
        if (index == 11) return "Gold Chain";
        if (index == 12) return "Silver Chain";
        if (index == 13) return "Bow Tie";
        if (index == 14) return "No Accessories";
        revert InvalidTraitIndex();
    }
}
