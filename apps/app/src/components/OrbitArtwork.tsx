import { AsciiGlobe } from './ascii';

/** Иллюстрация главной: вращающийся глобус из символов. */
export function OrbitArtwork(_props: { design?: unknown }) {
  return <div className="orbit-art ascii-art" aria-hidden="true"><AsciiGlobe /></div>;
}
