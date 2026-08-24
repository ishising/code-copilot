/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_COSMO_API_KEY: string;
  /** Optional. Lifts GitHub's 60-requests-per-hour anonymous limit to 5000,
   *  and is what lets the app read a private repository. */
  readonly VITE_GITHUB_TOKEN?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
