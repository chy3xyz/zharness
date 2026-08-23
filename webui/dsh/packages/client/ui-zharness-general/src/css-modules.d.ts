declare module '*.module.css' {
  /** CSS module class-name map (upstream web-styling discipline). */
  const classes: { readonly [key: string]: string }
  export default classes
}
