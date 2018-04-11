output "clone-ssh" {
  value = "${aws_codecommit_repository.blog.clone_url_ssh}"
}

output "ssh-key-id" {
  value = "${aws_iam_user_ssh_key.blog.ssh_public_key_id}"
}
