export default function ProtocolSelect({ value, onChange }) {
  return (
    <select value={value || 'tcp'} onChange={event => onChange(event.target.value)}>
      <option value="tcp">TCP</option>
      <option value="udp">UDP</option>
    </select>
  );
}
