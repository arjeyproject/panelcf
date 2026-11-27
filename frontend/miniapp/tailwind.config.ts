import type { Config } from "tailwindcss";

export default {
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  darkMode: "class",
  theme: {
    extend: {
      colors: {
        graphite: { 950: "#0B0E14", 900: "#121721", 800: "#1B2230", 700: "#263043" },
      },
    },
  },
  plugins: [],
} satisfies Config;
