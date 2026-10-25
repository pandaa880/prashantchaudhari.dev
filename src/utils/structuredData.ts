import { getImage } from "astro:assets";
import { SITE } from "@/config";
import { SOCIALS } from "@/constants";
import profilePicture from "@/assets/images/profile-picture.jpg";

const PERSON_ID = new URL("#person", SITE.website).href;
const WEBSITE_ID = new URL("#website", SITE.website).href;

/** Profile URLs (GitHub, X, LinkedIn) that identify the same person. */
const sameAs = SOCIALS.map(({ href }) => href).filter(href =>
  href.startsWith("https://")
);

/** Absolute URL of a 400x400 JPEG crop of the profile photo, for structured data. */
export const getProfileImageURL = async () => {
  const { src } = await getImage({
    src: profilePicture,
    width: 400,
    height: 400,
    fit: "cover",
    layout: "fixed",
    format: "jpg",
  });
  return new URL(src, SITE.website).href;
};

/** The site owner, linked to their public profiles via `sameAs`. */
export const getPersonSchema = (imageURL?: string) => ({
  "@type": "Person",
  "@id": PERSON_ID,
  name: SITE.author,
  url: SITE.website,
  jobTitle: "Senior Frontend Engineer",
  ...(imageURL && { image: imageURL }),
  sameAs,
});

/** Home page: the site itself plus its owner. */
export const getHomeSchema = (imageURL?: string) => ({
  "@context": "https://schema.org",
  "@graph": [
    {
      "@type": "WebSite",
      "@id": WEBSITE_ID,
      url: SITE.website,
      name: SITE.title,
      description: SITE.desc,
      inLanguage: SITE.lang || "en",
      publisher: { "@id": PERSON_ID },
    },
    getPersonSchema(imageURL),
  ],
});

/** About page: a profile page whose subject is the site owner. */
export const getProfilePageSchema = (pageURL: string, imageURL?: string) => ({
  "@context": "https://schema.org",
  "@type": "ProfilePage",
  url: pageURL,
  mainEntity: getPersonSchema(imageURL),
});
