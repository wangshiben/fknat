export default function Field({ title, hint, children }) {
  return (
    <label className="field">
      <span>{title}</span>
      {children}
      {hint ? <small>{hint}</small> : null}
    </label>
  );
}
