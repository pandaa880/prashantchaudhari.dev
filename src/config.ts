export const SITE = {
  website: "https://prashantchaudhari.dev/",
  author: "Prashant Chaudhari",
  profile: "https://prashantchaudhari.dev/",
  githubUsername: "pandaa880",
  desc: "Senior frontend engineer, seven years in: four on consumer credit products, now building verifiable credit on Solana. Notes on fintech UIs that show their work.",
  title: "Prashant Chaudhari",
  ogImage: undefined,
  lightAndDarkMode: true,
  postPerIndex: 4,
  postPerPage: 4,
  scheduledPostMargin: 15 * 60 * 1000, // 15 minutes
  showArchives: false,
  showBackButton: true, // show back button in post detail
  editPost: {
    enabled: true,
    text: "Edit page",
    url: "https://github.com/pandaa880/prashantchaudhari.dev/edit/main/",
  },
  dynamicOgImage: true,
  dir: "ltr", // "rtl" | "auto"
  lang: "en", // html lang code. Set this empty and default will be "en"
  timezone: "Asia/Kolkata", // Default global timezone (IANA format) https://en.wikipedia.org/wiki/List_of_tz_database_time_zones
} as const;
