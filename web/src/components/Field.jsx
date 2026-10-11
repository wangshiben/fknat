export default function Field({ title, hint, children }) {
  return (
    <label className="field">
      <span>{title}</span>
      <span className={hint ? 'field-control field-control-tooltip' : 'field-control'} title={hint || undefined} data-tooltip={hint || undefined}>
        {children}
      </span>
    </label>
  );
}
