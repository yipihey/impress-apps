import { auth } from "@/app/api/auth/[...nextauth]/route"
import { PrismaClient } from "@prisma/client"
import { NextResponse } from "next/server"

const prisma = new PrismaClient()

export async function GET(
  request: Request,
  { params }: { params: { id: string } }
) {
  const session = await auth()

  if (!session?.user?.id) {
    return NextResponse.json({ message: "Unauthorized" }, { status: 401 })
  }

  try {
    const { id } = params
    const publication = await prisma.publication.findUnique({
      where: { id, ownerId: session.user.id },
    })

    if (!publication) {
      return NextResponse.json({ message: "Publication not found" }, { status: 404 })
    }

    return NextResponse.json(publication)
  } catch (error) {
    console.error("Error fetching publication:", error)
    return NextResponse.json(
      { message: "Internal Server Error" },
      { status: 500 }
    )
  }
}

export async function PUT(
  request: Request,
  { params }: { params: { id: string } }
) {
  const session = await auth()

  if (!session?.user?.id) {
    return NextResponse.json({ message: "Unauthorized" }, { status: 401 })
  }

  try {
    const { id } = params
    const body = await request.json()
    const { title, author, bibtex, ...optionalFields } = body

    if (!title || !author || !bibtex) {
      return NextResponse.json(
        { message: "Missing required fields: title, author, bibtex" },
        { status: 400 }
      )
    }

    const updatedPublication = await prisma.publication.update({
      where: { id, ownerId: session.user.id },
      data: {
        title,
        author,
        bibtex,
        ...optionalFields,
      },
    })
    return NextResponse.json(updatedPublication)
  } catch (error) {
    console.error("Error updating publication:", error)
    return NextResponse.json(
      { message: "Internal Server Error" },
      { status: 500 }
    )
  }
}

export async function DELETE(
  request: Request,
  { params }: { params: { id: string } }
) {
  const session = await auth()

  if (!session?.user?.id) {
    return NextResponse.json({ message: "Unauthorized" }, { status: 401 })
  }

  try {
    const { id } = params
    await prisma.publication.delete({
      where: { id, ownerId: session.user.id },
    })
    return NextResponse.json({ message: "Publication deleted" }, { status: 200 })
  } catch (error) {
    console.error("Error deleting publication:", error)
    return NextResponse.json(
      { message: "Internal Server Error" },
      { status: 500 }
    )
  }
}
